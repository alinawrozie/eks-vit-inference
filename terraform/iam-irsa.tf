# iam-irsa.tf

# Part 1 — computed once, reused in both trust-policy conditions below
locals {
  oidc_provider = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
}

# Part 2 — trust policy: WHO can assume this role
data "aws_iam_policy_document" "melanoma_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    # Restricts assumption to exactly one ServiceAccount
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:vit-models:vit-melanoma-sa"]
    }

    # Confirms the token was actually issued for talking to AWS
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# Part 3 — the role itself, using the trust policy above
resource "aws_iam_role" "vit_melanoma_s3_read" {
  name               = "vit-melanoma-s3-read"
  assume_role_policy = data.aws_iam_policy_document.melanoma_assume_role.json
}

# Part 4 — permissions policy: WHAT the role can do, once assumed
data "aws_iam_policy_document" "melanoma_s3_permissions" {
  # GetObject scopes naturally by resource path
  statement {
    sid       = "GetMelanomaWeights"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.model_bucket.arn}/melanoma/*"]
  }

  # ListBucket is bucket-level, not path-level — the prefix condition
  # is what actually stops this role from listing keratosis's keys
  statement {
    sid       = "ListMelanomaPrefixOnly"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.model_bucket.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["melanoma/*"]
    }
  }
}

# Part 5 — attach inline, since this policy belongs to exactly one role
resource "aws_iam_role_policy" "vit_melanoma_s3_read" {
  name   = "s3-read-melanoma-weights"
  role   = aws_iam_role.vit_melanoma_s3_read.id
  policy = data.aws_iam_policy_document.melanoma_s3_permissions.json
}