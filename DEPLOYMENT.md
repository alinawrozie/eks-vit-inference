# Deployment runbook — eks-vit-inference

This reflects the actual order this project was built and verified in, not a speculative plan. Every command below, Steps 0–5, was genuinely executed and verified as written. **The project concluded at Step 5** — melanoma deployed, reachable via `kubectl port-forward`, verified with a real prediction. Steps 6–9 and a second model were deliberately not built; see the "Project conclusion" section at the end for why.

Placeholders used throughout: `<ACCOUNT_ID>`, `<TFSTATE_BUCKET>`, `<WEIGHTS_BUCKET>` (resolves to `${cluster_name}-weights-<ACCOUNT_ID>`), `<ECR_MELANOMA_URL>`. Commands are PowerShell-oriented where syntax differs from bash (backtick line continuation, `curl.exe`, `${PWD}`).

## Step 0 — Scope

No commands. Decisions made and held throughout: single best checkpoint per model (not the 5-fold ensemble), checkpoint filename and decision threshold (0.75) read from environment variables rather than hardcoded, two independent services designed for rather than one shared endpoint (though only melanoma was ultimately built — see the conclusion at the end of this file).

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

## Step 5 — Kubernetes workload objects — DONE, verified end-to-end

`terraform/outputs.tf` was added at this point — `account_id`, `ecr_melanoma_url`, `weights_bucket` — so none of the values below need retyping from memory:
```
terraform apply
terraform output account_id
terraform output ecr_melanoma_url
terraform output weights_bucket
```

**ECR login — do not use `--password-stdin` on PowerShell.** Piping through PowerShell's `|` appends a trailing newline to the token before `docker login` reads it, corrupting the auth request into a `400 Bad Request` (not a credentials error — the request itself is malformed). Capture the token into a variable instead, and run each command separately rather than pasting them together (a merged paste with no line break between commands caused the token to be swallowed as garbage arguments to `aws` in one run of this):
```
$token = aws ecr get-login-password --region eu-west-2
```
*(press Enter, confirm it returns before continuing)*
```
docker login --username AWS --password $token <ACCOUNT_ID>.dkr.ecr.eu-west-2.amazonaws.com
```
The `--password` CLI warning that follows is expected and fine here — this token expires in 12 hours and grants nothing beyond this one registry, unlike a real reusable credential.

If Docker Desktop's engine isn't responding (`failed to connect to the docker API at npipe://...`), it needs restarting — this happened mid-build once; see the note in Step 1 for the recovery steps, same fix applies here.

Build and push with an explicit version tag, not `latest` (the repo is `IMMUTABLE`, so re-pushing `v1` with different content fails on purpose):
```
docker build -t <ECR_MELANOMA_URL>:v1 ../containers/vit-melanoma
docker push <ECR_MELANOMA_URL>:v1
```
Confirm it actually landed, not just a clean exit code:
```
aws ecr describe-images --repository-name vit-melanoma --region eu-west-2
```

Upload the checkpoint — required every session, since `force_destroy` wipes the bucket on every teardown:
```
aws s3 cp local-weights/melanoma/melanoma-fold5.pt s3://<WEIGHTS_BUCKET>/melanoma/melanoma-fold5.pt
```

`k8s/vit-melanoma-deployment.yaml` and `k8s/vit-melanoma-service.yaml` — static YAML with real values filled in by hand (bucket name and ECR URL are stable enough not to warrant templating; see the deployment discussion in this repo's chat history for the reasoning). Apply both:
```
kubectl apply -f ../k8s/vit-melanoma-deployment.yaml
kubectl apply -f ../k8s/vit-melanoma-service.yaml
kubectl get pods -n vit-models -w
```
Both replicas reached `1/1 Ready` within ~20 seconds — init container fetched the checkpoint via IRSA, main container passed its `/health` readiness check.

**Final proof — the project's actual finish line, verified without an ALB (Step 6 was not built; `port-forward` was the last mile for this project's scope):**
```
kubectl port-forward -n vit-models svc/vit-melanoma-svc 8080:80
```
```
curl.exe -X POST -F "file=@test-images/test.jpg" http://localhost:8080/predict
```
Result: `{"probability":0.5621392726898193,"label":0}` — bit-for-bit identical to the first local prediction from Step 1, confirming the checkpoint fetched via IRSA is byte-identical to the local copy and nothing in the container/EKS/IRSA chain introduced drift.

## Steps 6–9 — out of scope, not built

ALB Ingress, Horizontal Pod Autoscaler, CI/CD, and observability were all planned and partially designed (see this repo's chat history for the ALB controller/Ingress reasoning specifically) but never implemented. This was a deliberate scope decision, not a stopping point reached by running out of time or hitting a blocker — Step 5 already proves everything this project set out to prove.

## Tearing down

```
terraform destroy
```
Deletes everything, including the S3 bucket's contents (`force_destroy`) and the Terraform-generated ServiceAccount YAML. Nothing here is stateful or irreplaceable — the checkpoint's source of truth is `local-weights/`, everything else rebuilds from `.tf` files.

## Project conclusion

Final verified state: a raw image, sent to a pod running in Amazon EKS, returns a real prediction — `{"probability":0.5621392726898193,"label":0}`, bit-for-bit identical to the very first local test in Step 1. Zero static AWS credentials anywhere in the system; a least-privilege IAM boundary that was proven to actually hold, not just configured; infrastructure that tears down and rebuilds cleanly from code alone. That's the goal this project was scoped around, and it's met.

If this project is ever picked back up, Step 3's `update-kubeconfig` reminder and Step 4/5's `force_destroy`-driven re-upload step are the two things most likely to trip up a fresh restart — worth rereading those two sections first rather than starting from memory.