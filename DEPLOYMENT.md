# Deployment runbook — eks-vit-inference

This reflects the actual order this project was built and verified in, not a speculative plan. Steps 0–4 are complete and were genuinely executed as written below. Steps 5 onward are the plan for what comes next — update this file as each is actually completed, so it never drifts back into being aspirational rather than real.

Placeholders used throughout: `<ACCOUNT_ID>`, `<TFSTATE_BUCKET>`, `<WEIGHTS_BUCKET>` (resolves to `${cluster_name}-weights-<ACCOUNT_ID>`), `<ECR_MELANOMA_URL>`. Commands are PowerShell-oriented where syntax differs from bash (backtick line continuation, `curl.exe`, `${PWD}`).

## Step 0 — Scope

No commands. Decisions made and held throughout: single best checkpoint per model (not the 5-fold ensemble), melanoma built as one complete vertical slice before keratosis, checkpoint filename and decision threshold (0.75) read from environment variables rather than hardcoded, two independent services rather than one shared endpoint.

## Step 1 — Local containerization

From `containers/vit-melanoma/`:
```
docker build -t vit-melanoma:local .
```
From the repo root, with the checkpoint mounted from the host (never baked into the image):
```
docker run -p 8080:8080 -v "${PWD}\local-weights\melanoma:/weights" -e CHECKPOINT_PATH=/weights/melanoma-fold5.pt -e THRESHOLD=0.75 vit-melanoma:local
```

Verify, in a second terminal:
```
curl.exe http://localhost:8080/health
curl.exe -X POST -F "file=@test-images/test.jpg" http://localhost:8080/predict
```

Negative tests — both required, not optional, since they prove the fail-loudly behavior actually works:
- Rerun with a `CHECKPOINT_PATH` that doesn't exist → container must fail to start, not silently serve a broken model.
- POST a non-image file to `/predict` → must return `400`, not `500`.

## Step 2 — AWS foundations (Terraform)

**Bootstrap the Terraform state bucket manually, once, outside Terraform** — this can't be created by the same config that depends on it existing:
```
aws s3api create-bucket --bucket <TFSTATE_BUCKET> --region eu-west-2 --create-bucket-configuration LocationConstraint=eu-west-2
aws s3api put-bucket-versioning --bucket <TFSTATE_BUCKET> --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket <TFSTATE_BUCKET> --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

`terraform/providers.tf` — S3 backend with native locking (`use_lockfile = true`, requires Terraform ≥ 1.11), `terraform/variables.tf` (`aws_region`, `cluster_name`), `terraform/vpc.tf` (VPC module, single NAT Gateway, public + private subnets across 2 AZs, ELB subnet tags), `terraform/vpc-endpoints.tf` (free S3 Gateway Endpoint — see ADR 0001 for why Interface Endpoints were considered and not used).

From `terraform/`:
```
terraform init
terraform plan
terraform apply
```

## Step 3 — EKS cluster

`terraform/eks.tf` — EKS module, `cluster_version = "1.32"`, both public and private API endpoint access enabled, `enable_irsa = true`, `enable_cluster_creator_admin_permissions = true` (required in module v20+, or your own IAM user gets no cluster access after apply), managed node group (`t3.medium`, 2 nodes).

```
terraform apply
```
Expect the control plane alone to take 7–8 minutes.

**Every time the cluster is destroyed and recreated, this must be rerun before any `kubectl` command** — a new cluster gets a new API endpoint hostname, and a stale `kubeconfig` fails with a DNS lookup error, not a permissions error:
```
aws eks update-kubeconfig --name eks-vit-inference --region eu-west-2
kubectl get nodes
```

## Step 4 — Storage wiring: S3, ECR, IRSA

`terraform/s3.tf` (weights bucket, name suffixed with the account ID for guaranteed uniqueness, `force_destroy = true`), `terraform/ecr.tf` (`vit-melanoma` repo, immutable tags, scan on push), `terraform/iam-irsa.tf` (melanoma's IAM role — trust policy scoped to `system:serviceaccount:vit-models:vit-melanoma-sa` with both `sub` and `aud` conditions; permissions policy split into a `GetObject` statement scoped by path and a separate `ListBucket` statement scoped by an `s3:prefix` condition), `terraform/k8s-templates.tf` (renders `k8s/generated/serviceaccount-melanoma.yaml` from `k8s/templates/serviceaccount-melanoma.yaml.tpl`, injecting the real IRSA role ARN — no manual copy-paste).

```
terraform apply
```

Confirm the ServiceAccount YAML actually rendered with a real ARN, not the placeholder:
```
cat ../k8s/generated/serviceaccount-melanoma.yaml
```

Apply to the cluster:
```
kubectl apply -f ../k8s/namespace.yaml
kubectl apply -f ../k8s/generated/serviceaccount-melanoma.yaml
```

Upload the checkpoint — this bucket is emptied by `force_destroy` every time the infrastructure is torn down, so this step repeats every session:
```
aws s3 cp local-weights/melanoma/melanoma-fold5.pt s3://<WEIGHTS_BUCKET>/melanoma/melanoma-fold5.pt
```

**Verify IRSA end-to-end with a disposable pod** (`kubectl run --serviceaccount` is removed in current `kubectl` — use a plain pod manifest instead):
```yaml
# k8s/irsa-test-pod.yaml — throwaway, not part of the real deployment
apiVersion: v1
kind: Pod
metadata:
  name: irsa-test
  namespace: vit-models
spec:
  serviceAccountName: vit-melanoma-sa
  containers:
    - name: irsa-test
      image: amazon/aws-cli:2.15.0
      command: ["sleep", "3600"]
```
```
kubectl apply -f k8s/irsa-test-pod.yaml
kubectl exec -it irsa-test -n vit-models -- sh
```
Inside the pod:
```
aws sts get-caller-identity
# Arn must show assumed-role/vit-melanoma-s3-read/..., not the node's own role

aws s3 cp s3://<WEIGHTS_BUCKET>/melanoma/melanoma-fold5.pt /tmp/test.pt
# must succeed

aws s3 ls s3://<WEIGHTS_BUCKET>/
# must fail with AccessDenied — proves the prefix condition works

aws s3 ls s3://<WEIGHTS_BUCKET>/melanoma/
# must succeed (note the trailing slash — without it, the literal prefix
# sent doesn't match the "melanoma/*" condition and is denied too)
```
Clean up:
```
exit
kubectl delete pod irsa-test -n vit-models
```

## Step 5 — Kubernetes workload objects (not yet executed — plan below)

Push the real image, using an explicit version tag, not `latest` (the ECR repo is `IMMUTABLE`, so re-pushing the same tag will fail on purpose):
```
aws ecr get-login-password --region eu-west-2 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.eu-west-2.amazonaws.com
docker build -t <ECR_MELANOMA_URL>:v1 containers/vit-melanoma
docker push <ECR_MELANOMA_URL>:v1
```

Write `k8s/vit-melanoma-deployment.yaml` and `k8s/vit-melanoma-service.yaml`, with the init container pulling `melanoma/melanoma-fold5.pt` and the real `<ECR_MELANOMA_URL>:v1` image — no placeholders left in either file.

```
kubectl apply -f k8s/vit-melanoma-deployment.yaml
kubectl apply -f k8s/vit-melanoma-service.yaml
kubectl get pods -n vit-models -w
```

Prove it end-to-end without waiting for Step 6's ALB:
```
kubectl port-forward -n vit-models svc/vit-melanoma-svc 8080:80
```
```
curl.exe -X POST -F "file=@test-images/test.jpg" http://localhost:8080/predict
```

## Steps 6–9 (not started)

Ingress/ALB, HPA, CI/CD, and observability — to be filled in here as each is actually built, following the same "what was really run" standard as the sections above.

## Tearing down

```
terraform destroy
```
Deletes everything, including the S3 bucket's contents (`force_destroy`) and the Terraform-generated ServiceAccount YAML. Nothing here is stateful or irreplaceable — the checkpoint's source of truth is `local-weights/`, everything else rebuilds from `.tf` files. Re-running Step 4's upload and Step 3's `update-kubeconfig` are the two things every fresh `apply` requires again before continuing.