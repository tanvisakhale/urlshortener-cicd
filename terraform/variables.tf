variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Name prefix used for tagging and resource naming"
  type        = string
  default     = "url-shortener"
}

variable "environment" {
  description = "Deployment environment (staging or production)"
  type        = string
  default     = "staging"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones to spread subnets across"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.30"
}

variable "eks_node_instance_types" {
  description = "Instance types for the EKS managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_node_desired_size" {
  type    = number
  default = 2
}

variable "eks_node_min_size" {
  type    = number
  default = 2
}

variable "eks_node_max_size" {
  type    = number
  default = 4
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  type    = string
  default = "urlshortener"
}

variable "db_username" {
  description = "Master username for RDS. Password is generated and stored in Secrets Manager, never in tfvars."
  type        = string
  default     = "urlshortener_admin"
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 20
}

variable "github_repository" {
  description = "GitHub repo in 'org/name' form, used to scope the OIDC trust policy"
  type        = string
  default     = "your-org/urlshortener-cicd"
}

variable "manage_shared_resources" {
  description = <<-EOT
    This config is intended to be applied once per environment (staging,
    production), each typically as its own `terraform workspace` or
    state file. Most resources (VPC, EKS, RDS) are correctly namespaced
    per-environment already. But two resources are AWS-account-global
    and must exist exactly once no matter how many environments you
    apply: the GitHub OIDC provider (one per unique provider URL per
    account) and the ECR repository (images are built once in CI and
    the *same* tag is promoted staging -> production, so one shared
    repo is also the technically correct choice, not just a workaround).

    Set this to true on the FIRST environment you apply (e.g. staging)
    so Terraform creates them, and to false on every subsequent
    environment (e.g. production) so Terraform looks them up via data
    source instead of trying to recreate them.
  EOT
  type        = bool
  default     = true
}
