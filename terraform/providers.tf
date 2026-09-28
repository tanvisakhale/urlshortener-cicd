terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Recommended for real use: a remote backend (S3 + DynamoDB lock table)
  # instead of local state. Left commented out because it requires
  # pre-existing bootstrap resources.
  #
  # backend "s3" {
  #   bucket         = "url-shortener-terraform-state"
  #   key            = "url-shortener/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "url-shortener-terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}
