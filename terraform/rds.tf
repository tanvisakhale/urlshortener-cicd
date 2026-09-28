# SECURITY NOTE (honest, not aspirational):
#
# We intentionally do NOT generate the password with Terraform's
# `random_password` and pass it into `aws_db_instance.password`. Doing that
# would put the plaintext password directly into Terraform state -- state
# is not a secrets store, and "Terraform never sees the password" would be
# a false claim if we did that.
#
# Instead we use RDS's native "manage_master_user_password" feature: AWS
# itself generates the password and stores it in a Secrets Manager secret
# that Terraform never reads and that never appears in Terraform state.
# The application/CI only ever reads it back via the AWS Secrets Manager
# API (using IAM, not Terraform), scoped to exactly this one secret ARN.
resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-${var.environment}"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# Only the EKS node security group may reach Postgres -- the DB is never
# publicly reachable.
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-rds"
  description = "Allow Postgres access from EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.project_name}-${var.environment}"
  engine         = "postgres"
  engine_version = "16.4"

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username

  # AWS generates and rotates the master password and stores it in a
  # Secrets Manager secret it manages -- Terraform, its state, and this
  # repo never contain the plaintext value.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az                = var.environment == "production"
  backup_retention_period = var.environment == "production" ? 7 : 1
  deletion_protection     = var.environment == "production"
  skip_final_snapshot     = var.environment != "production"

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
