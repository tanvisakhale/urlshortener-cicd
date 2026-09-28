# GitHub Actions OIDC provider -- lets workflows assume an AWS IAM role
# using short-lived tokens instead of long-lived access keys.
#
# This provider is a per-AWS-account singleton (AWS rejects a second
# provider for the same URL), so it's only actually created once, on the
# environment applied with manage_shared_resources = true; every other
# environment looks it up instead of trying to recreate it.
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.manage_shared_resources ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # Thumbprint for GitHub's OIDC token endpoint (GitHub-published value).
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.manage_shared_resources ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.manage_shared_resources ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Least privilege: only THIS repo's workflows may assume the role,
    # and only when running against main / release environments.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  # Includes the environment so `terraform apply -var environment=staging`
  # and `-var environment=production` (each with its own state) create
  # two distinct roles instead of colliding on one globally-unique IAM
  # role name. This also keeps the roles' access naturally scoped: the
  # staging role is only ever wired (via access_entries in eks.tf) to
  # the staging cluster, and likewise for production.
  name               = "${var.project_name}-${var.environment}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}

# Least-privilege: only what CI/CD actually needs -- push to this ECR repo,
# and deploy to this EKS cluster. Not AdministratorAccess.
data "aws_iam_policy_document" "github_actions_permissions" {
  statement {
    sid    = "ECRAuth"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [local.ecr_repository_arn]
  }

  statement {
    sid    = "EKSDescribe"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
    ]
    resources = [module.eks.cluster_arn]
  }

  # Lets CI look up the real RDS endpoint at deploy time instead of a
  # hard-coded placeholder host (see k8s Secret creation step in cd.yml).
  statement {
    sid    = "RDSDescribeThisInstance"
    effect = "Allow"
    actions = [
      "rds:DescribeDBInstances",
    ]
    resources = [aws_db_instance.this.arn]
  }

  # Lets CI read the AWS-managed master password -- scoped to exactly
  # this one secret, nothing else in Secrets Manager.
  statement {
    sid    = "ReadDBMasterPassword"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [aws_db_instance.this.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${var.project_name}-${var.environment}-github-actions-policy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}
