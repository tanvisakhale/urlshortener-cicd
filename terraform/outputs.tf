output "vpc_id" {
  value = module.vpc.vpc_id
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_repository_url" {
  value = local.ecr_repository_url
}

output "rds_instance_identifier" {
  value = aws_db_instance.this.identifier
}

output "rds_endpoint" {
  description = "RDS hostname (not sensitive on its own; used as DATABASE_HOST)"
  value       = aws_db_instance.this.address
}

output "rds_port" {
  value = aws_db_instance.this.port
}

output "db_master_user_secret_arn" {
  description = "ARN of the AWS-managed Secrets Manager secret holding the RDS master password. CD reads this via 'aws secretsmanager get-secret-value', never via Terraform."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "github_actions_role_arn" {
  description = "Put this in the GitHub Actions workflow's role-to-assume input"
  value       = aws_iam_role.github_actions.arn
}
