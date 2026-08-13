#This file is going to create service account for the melanoma model
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vit-melanoma-sa
  namespace: vit-models
  annotations:
    eks.amazonaws.com/role-arn: ${role_arn}