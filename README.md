# eks-vit-inference

Containerized inference service for a ViT-B16 skin lesion classifier, deployed on Amazon EKS, provisioned with Terraform, model weights served securely from S3 via IRSA.

## What this is

This repository takes a trained ViT-B16 skin lesion classifier - originally trained and evaluated in [skin-cancer-classification](../skin-cancer-classification) - and deploys it as a real, containerized inference service on Kubernetes. The model itself isn't the point of this repo; the infrastructure is. This is a hands-on build covering Docker, Kubernetes (Amazon EKS), Terraform, and the AWS networking/IAM decisions that come with running a real workload in private subnets.

The source project trains two independent classifiers - melanoma-vs-others and keratosis-vs-others. This repo deploys **melanoma only**, as a deliberate, final scope decision, not an in-progress step. The melanoma build proves the full pattern end to end - containerization, EKS, Terraform, IRSA, least-privilege IAM, S3 storage; a second service would largely repeat already-proven steps rather than add new learning, so it was intentionally left unbuilt.

## Architecture

| Layer | Choice |
|---|---|
| Container runtime | Docker, FastAPI inference app (CPU-only PyTorch) |
| Orchestration | Kubernetes on Amazon EKS |
| Infrastructure as Code | Terraform, remote state in S3 with native locking (no DynamoDB) |
| Model weight storage | S3, versioned bucket, fetched by an init container at pod startup |
| Pod → AWS authentication | IRSA (IAM Roles for Service Accounts) - no static AWS credentials anywhere |
| Container registry | Amazon ECR, immutable image tags |
| Network egress | Single NAT Gateway + free S3 Gateway Endpoint - see [ADR 0001](docs/adr/0001-network-egress-strategy.md) for the full reasoning |

The weights bucket and IAM role are scoped by S3 key prefix (`melanoma/`) rather than granted broad bucket access - a deliberate least-privilege choice made independent of whether a second model ever exists, not a feature built in anticipation of one.

## Repository structure

```
eks-vit-inference/
├── containers/
│   └── vit-melanoma/
│       ├── Dockerfile
│       ├── app.py              # FastAPI inference service
│       ├── model.py            # ViT-B16 architecture + preprocessing (matches training)
│       └── requirements.txt
├── docs/
│   └── adr/
│       └── 0001-network-egress-strategy.md
├── k8s/
│   ├── namespace.yaml
│   ├── vit-melanoma-deployment.yaml
│   ├── vit-melanoma-service.yaml
│   ├── templates/
│   │   └── serviceaccount-melanoma.yaml.tpl   # source of truth, no hardcoded ARN
│   └── generated/              # produced by `terraform apply`, gitignored
├── terraform/
│   ├── providers.tf            # AWS provider + S3 backend, native locking
│   ├── variables.tf
│   ├── vpc.tf                  # VPC, public/private subnets across 2 AZs, single NAT
│   ├── vpc-endpoints.tf        # free S3 Gateway Endpoint
│   ├── eks.tf                  # EKS cluster + managed node group
│   ├── s3.tf                   # weights bucket (versioned, encrypted, private)
│   ├── ecr.tf                  # container image repository
│   ├── iam-irsa.tf             # melanoma's scoped IAM role + trust policy
│   ├── k8s-templates.tf        # renders the ServiceAccount YAML with the real IRSA ARN
│   └── outputs.tf              # account_id, ecr_melanoma_url, weights_bucket
├── local-weights/               # local checkpoint copy for testing, gitignored
├── DEPLOYMENT.md
└── README.md
```

## Status - project concluded

| Step | What it covers | Status |
|---|---|---|
| 0 | Scope, input/output contract, checkpoint & threshold | Done |
| 1 | Local containerization, tested with negative cases | Done |
| 2 | AWS foundations - VPC, remote state, NAT, free S3 endpoint | Done |
| 3 | EKS cluster, node group, OIDC provider for IRSA | Done |
| 4 | S3 + IRSA wiring, proven end-to-end from a real pod | Done |
| 5 | Kubernetes Deployment/Service, port-forward test | Done - final milestone |
| 6 | ALB Ingress, external reachability | Out of scope |
| 7 | Horizontal Pod Autoscaler | Out of scope |
| 8 | CI/CD (GitHub Actions → ECR) | Out of scope |
| 9 | Observability (CloudWatch Container Insights) | Out of scope |
| — | Keratosis service | Out of scope - not built, by design |

IRSA verification (Step 4) was proven with a disposable test pod: `aws sts get-caller-identity` confirmed the pod assumed the melanoma role (not the node's own identity); reading `melanoma/*` succeeded; listing the bucket root correctly failed with `AccessDenied`, proving the prefix-scoped permissions boundary actually holds.

Step 5 closed with a full end-to-end prediction from a real pod in EKS - `{"probability":0.5621392726898193,"label":0}`, bit-for-bit identical to the first local prediction from Step 1, confirming nothing in the container/EKS/IRSA chain introduced drift from the model's actual behavior. This was the project's final milestone.

## Project conclusion

This project set out to containerize and deploy a trained ViT-B16 skin lesion classifier on Kubernetes, provisioned entirely through Terraform, with secure and least-privilege access to model weights. That goal was met and verified: a raw image, sent to a pod running in Amazon EKS, returns a real prediction - with zero static AWS credentials anywhere in the system, a scoped IAM boundary proven to actually hold (not just configured), and infrastructure that tears down and rebuilds cleanly from code alone.

Everything past this point - external ALB access, autoscaling, CI/CD, observability, and a second model - is real, well-understood follow-on work, not something left unfinished by oversight. It's out of scope by deliberate choice: the melanoma build already exercises every mechanism (IRSA, least-privilege IAM, Terraform module usage vs. hand-written resources, container-to-Kubernetes networking) this project was meant to prove out. Should any of Steps 6–9 or a second model become worth doing later, `docs/adr/0001-network-egress-strategy.md` and this README's architecture notes are written to still be accurate starting points.

## Prerequisites

- AWS account with credentials configured (`aws sts get-caller-identity` should succeed)
- Terraform ≥ 1.11 (required for native S3 state locking)
- Docker
- `kubectl`
- An S3 bucket + your AWS account ID for the Terraform state backend (bootstrap steps in `docs/adr/`, since this can't be created by the same Terraform config that depends on it)

## Running this

See `DEPLOYMENT.md` for the full ordered runbook, ending at the actual final state of this project. Rough shape: `terraform apply` in `terraform/` (provisions everything, including rendering the ServiceAccount YAML with the real IRSA role ARN), `aws eks update-kubeconfig`, `kubectl apply` the namespace and generated ServiceAccount, upload the checkpoint to S3, then apply the Deployment/Service manifests and test with `kubectl port-forward`.

## Cost

This provisions real, billable AWS infrastructure - primarily a NAT Gateway and the EKS control plane, both charged hourly regardless of usage. Nothing here is free to leave running. `terraform destroy` tears down everything cleanly (state and Terraform's own generated files included) and is meant to be run whenever this isn't being actively worked on - see the network egress ADR for the specific cost trade-offs behind the NAT Gateway choice.