output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "ecr_melanoma_url" {
  value = aws_ecr_repository.vit_melanoma.repository_url
}

