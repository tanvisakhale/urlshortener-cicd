module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.project_name}-${var.environment}"
  cluster_version = var.eks_cluster_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true # demo convenience; restrict via CIDR allow-list in real prod

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      instance_types = var.eks_node_instance_types
      desired_size   = var.eks_node_desired_size
      min_size       = var.eks_node_min_size
      max_size       = var.eks_node_max_size
      subnet_ids     = module.vpc.private_subnets
    }
  }

  # Grants the GitHub Actions IAM role access to THIS cluster only, using
  # the EKS "Edit" access policy rather than "ClusterAdmin". Edit allows
  # creating/updating/deleting workloads (Deployments, Services,
  # ConfigMaps, Secrets, HPAs) -- exactly what the CD pipeline needs --
  # without granting RBAC/cluster-admin-level control-plane permissions
  # (e.g. it cannot modify other IAM/RBAC bindings or cluster-wide
  # security policy). Since staging and production are separate EKS
  # clusters (see naming above), scope=cluster here is still least
  # privilege in practice: the staging role can't touch the production
  # cluster and vice versa, because each Terraform apply only grants
  # access to the cluster it creates.
  access_entries = {
    github_actions = {
      principal_arn = aws_iam_role.github_actions.arn
      policy_associations = {
        deploy = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# So EKS can pull images from ECR and so kubectl can address the cluster.
#
# One shared repository across environments -- CI builds the image ONCE
# and the same immutable, commit-SHA-tagged image is promoted from
# staging to production, so a single repo is the technically correct
# choice, not just a naming workaround. Only created on the environment
# applied with manage_shared_resources = true; other environments look
# it up via data source (repo names must be globally unique per account
# too, so creating it twice would fail).
resource "aws_ecr_repository" "app" {
  count                = var.manage_shared_resources ? 1 : 0
  name                 = var.project_name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}

data "aws_ecr_repository" "app" {
  count = var.manage_shared_resources ? 0 : 1
  name  = var.project_name
}

locals {
  ecr_repository_arn = var.manage_shared_resources ? aws_ecr_repository.app[0].arn : data.aws_ecr_repository.app[0].arn
  ecr_repository_url = var.manage_shared_resources ? aws_ecr_repository.app[0].repository_url : data.aws_ecr_repository.app[0].repository_url
}
