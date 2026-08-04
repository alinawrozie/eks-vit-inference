variable "aws_region" {
  description = "The Primary AWS Region for all resources"
  type        = string
  default     = "eu-west-2"
}

variable "cluster_name" {
  description = "Name for the EKS cluster and related resource tagging"
  type        = string
  default     = "eks-vit-inference"
}