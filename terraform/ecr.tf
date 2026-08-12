resource "aws_ecr_repository" "vit_melanoma" {
    name = "vit-melanoma"
    image_tag_mutability = "IMMUTABLE"
    image_scanning_configuration {
        scan_on_push = true
    }
}