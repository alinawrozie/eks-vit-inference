apiVersion: v1
kind: ServiceAccount
metadata:
  name: vit-melanoma-sa
  namespace: vit-models
  annotations:
    eks.amazonaws.com/role-arn: ${role_arn}