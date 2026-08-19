resource "aws_ecr_repository" "vit_melanoma" {
  name                 = "vit-melanoma"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}