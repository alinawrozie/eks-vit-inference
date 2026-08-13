resource "local_file" "serviceaccount_melanoma" {
  content = templatefile("${path.module}/../k8s/templates/serviceaccount-melanoma.yaml.tpl", {
    role_arn = aws_iam_role.vit_melanoma_s3_read.arn
  })
  filename = "${path.module}/../k8s/generated/serviceaccount-melanoma.yaml"
}