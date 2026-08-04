terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket = "eks-vit-inference-tfstate-lock"
    key    = "eks-vit-inference/terraform.tfstate"
    region = "eu-west-2"
    encrypt = true
    use_lockfile = true
  }
}

# Primary region for most resources.
provider "aws" {
  region = var.aws_region
}

