variable "aws_region" {
  description = "The Primary AWS Region for all resources"
  type        = string
  default     = "eu-west-2"
}

# NOTE: This value is reused beyond just the EKS cluster name — it's also
# interpolated into the S3 bucket name in s3.tf (e.g. "${var.cluster_name}-weights-<account_id>").
# EKS naming rules allow underscores; S3 bucket names do not. If you ever
# change this default, make sure the new value is still valid as an S3
# bucket name component (lowercase letters, numbers, hyphens only) or the
# S3 bucket resource will fail even though the EKS cluster name is fine.
variable "cluster_name" {
  description = "Name for the EKS cluster; also reused as a prefix for the S3 weights bucket name"
  type        = string
  default     = "eks-vit-inference"
}
