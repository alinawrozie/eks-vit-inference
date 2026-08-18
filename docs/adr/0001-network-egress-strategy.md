# ADR 0001: Network egress strategy for private subnets

**Status:** Accepted
**Date:** 2026-08-05
**Context:** eks-vit-inference — Amazon EKS deployment of two independent ViT-B16 skin lesion classifiers

## Context

Both model services run in private subnets with no direct route to the internet, by design. At pod startup, each pod needs outbound access to three AWS services: **ECR** (pulling its container image), **S3** (fetching its model checkpoint), and **STS** (exchanging its Kubernetes identity for temporary AWS credentials via IRSA). Separately, cluster-level components need outbound access too — the AWS Load Balancer Controller calls the **EC2** and **ELB** APIs to provision and manage the ALB, and pod logs ship to **CloudWatch Logs**.

None of this outbound access is needed for serving inference requests. Client traffic reaches pods entirely through the ALB, which is inbound traffic terminating at a public-facing load balancer — a separate concern from the egress question this ADR addresses.

Two mechanisms can provide that outbound path: a **NAT Gateway**, or a set of **VPC Endpoints** (a free Gateway endpoint for S3, and paid Interface endpoints for everything else).

## Decision

Use a **single NAT Gateway**, in one Availability Zone, alongside the free **S3 Gateway Endpoint**.

## Options considered

| Option | Est. monthly cost | Internet route from private subnets? |
|---|---|---|
| No NAT, no endpoints | $0 | Not viable — pods cannot start |
| S3 Gateway endpoint only | $0 | Insufficient alone — ECR/STS/EC2/ELB/Logs still unreachable |
| **Single NAT Gateway + free S3 Gateway endpoint (chosen)** | **~$35–40** | Yes, via NAT |
| 6 Interface endpoints, single-AZ each, + free S3 Gateway | ~$43 | None |
| 6 Interface endpoints, mixed AZ coverage, + free S3 Gateway | ~$65 | None |
| 6 Interface endpoints, dual-AZ each, + free S3 Gateway | ~$86 | None |
| NAT Gateway *and* all Interface endpoints | $75–125+ | Yes — redundant, no architectural reason to combine |

## Rationale

The Interface Endpoint approach is the more architecturally isolated option: private subnets would have literally no route to the public internet, which removes an entire class of exfiltration risk regardless of any IAM misconfiguration elsewhere. That property is real and would be the right default for a production workload handling sensitive data, operated by a team, under any compliance obligation.

None of those conditions apply here. This is a self-funded, single-operator learning project with no other tenant and no realistic adversary incentive beyond what IAM and security groups already constrain. The endpoint approach costs roughly $30–50/month more than NAT for a security property this project's threat model does not currently need — spending money to eliminate a risk that isn't meaningfully present.

The S3 Gateway endpoint is taken regardless of which option is chosen, since it is free and strictly removes S3 traffic from the NAT path at no cost.

## Consequences

- All non-S3 outbound traffic (ECR pulls, STS calls, ALB controller reconciliation, log shipping) passes through one NAT Gateway in a single AZ.
- **Single point of failure, accepted deliberately:** if that Availability Zone has an outage, pods in the other AZ also lose outbound access, even though they themselves are unaffected. Given this project's availability requirements (none — it is not serving external users on an SLA), this is an acceptable trade-off, not an oversight.
- **Cross-AZ data transfer:** traffic from the AZ without the NAT Gateway incurs a small additional per-GB charge crossing to reach it, on top of NAT's own per-GB data-processing charge. At this project's traffic volume, this is negligible in absolute terms.
- Should this project's scope ever change — a second operator, external users, any compliance requirement — this decision should be revisited. The Interface Endpoint architecture remains fully understood and specified in the options table above, and is a straightforward migration if the risk profile changes.