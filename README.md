# eks-vit-inference

Containerized inference service for a ViT-B16 skin lesion classifier — deployed on Amazon EKS, provisioned with Terraform, model weights served securely from S3 via IRSA.

## What this is

This repository takes a trained ViT-B16 skin lesion classifier — originally trained and evaluated in [skin-cancer-classification](../skin-cancer-classification) — and deploys it as a real, containerized inference service on Kubernetes. The model itself isn't the point of this repo; the infrastructure is. This is a hands-on build covering Docker, Kubernetes (Amazon EKS), Terraform, and the AWS networking/IAM decisions that come with running a real workload in private subnets.

Two independent classifiers exist in the source project — melanoma-vs-others and keratosis-vs-others. This repo currently deploys **melanoma only**, built as a complete, working vertical slice end to end before repeating the same pattern for keratosis.

## Architecture

| Layer | Choice |
|---|---|
| Container runtime | Docker, FastAPI inference app (CPU-only PyTorch) |
| Orchestration | Kubernetes on Amazon EKS |
| Infrastructure as Code | Terraform, remote state in S3 with native locking (no DynamoDB) |
| Model weight storage | S3, versioned bucket, fetched by an init container at pod startup |
| Pod → AWS authentication | IRSA (IAM Roles for Service Accounts) — no static AWS credentials anywhere |
| Container registry | Amazon ECR, immutable image tags |
| Network egress | Single NAT Gateway + free S3 Gateway Endpoint — see [ADR 0001](docs/adr/0001-network-egress-strategy.md) for the full reasoning |

The weights bucket is shared across both models by S3 key prefix (`melanoma/`, `keratosis/`); each model has its own IAM role, scoped by trust-policy condition to its own ServiceAccount, and by permissions policy to its own prefix. A compromised melanoma pod cannot read keratosis's weights, or vice versa.

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
│   └── k8s-templates.tf        # renders the ServiceAccount YAML with the real IRSA ARN
├── local-weights/               # local checkpoint copy for testing, gitignored
├── DEPLOYMENT.md
└── README.md
```

## Status

| Step | What it covers | Status |
|---|---|---|
| 0 | Scope, input/output contract, checkpoint & threshold | Done |
| 1 | Local containerization, tested with negative cases | Done |
| 2 | AWS foundations — VPC, remote state, NAT, free S3 endpoint | Done |
| 3 | EKS cluster, node group, OIDC provider for IRSA | Done |
| 4 | S3 + IRSA wiring, proven end-to-end from a real pod | Done |
| 5 | Kubernetes Deployment/Service, port-forward test | In progress |
| 6 | ALB Ingress, external reachability | Not started |
| 7 | Horizontal Pod Autoscaler | Not started |
| 8 | CI/CD (GitHub Actions → ECR) | Not started |
| 9 | Observability (CloudWatch Container Insights) | Not started |
| — | Keratosis service (repeats this same pattern) | Deferred until melanoma is fully live |

IRSA verification (Step 4) was proven with a disposable test pod: `aws sts get-caller-identity` confirmed the pod assumed the melanoma role (not the node's own identity); reading `melanoma/*` succeeded; listing the bucket root correctly failed with `AccessDenied`, proving the prefix-scoped permissions boundary actually holds.

## Prerequisites

- AWS account with credentials configured (`aws sts get-caller-identity` should succeed)
- Terraform ≥ 1.11 (required for native S3 state locking)
- Docker
- `kubectl`
- An S3 bucket + your AWS account ID for the Terraform state backend (bootstrap steps in `docs/adr/`, since this can't be created by the same Terraform config that depends on it)

## Running this

See `DEPLOYMENT.md` for the full ordered runbook. Rough shape: `terraform apply` in `terraform/` (provisions everything, including rendering the ServiceAccount YAML with the real IRSA role ARN), `aws eks update-kubeconfig`, `kubectl apply` the namespace and generated ServiceAccount, upload the checkpoint to S3, then apply the Deployment/Service manifests once Step 5 is complete.

## Cost

This provisions real, billable AWS infrastructure — primarily a NAT Gateway and the EKS control plane, both charged hourly regardless of usage. Nothing here is free to leave running. `terraform destroy` tears down everything cleanly (state and Terraform's own generated files included) and is meant to be run whenever this isn't being actively worked on — see the network egress ADR for the specific cost trade-offs behind the NAT Gateway choice.