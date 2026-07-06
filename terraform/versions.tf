terraform {
  # >= 1.11.0 is required for ephemeral variables and write-only arguments
  # (used in rds.tf for password_wo, so the RDS master password never
  # gets written to terraform.tfstate).
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# AWS provider is configured via the aws_region variable.
# Credentials are expected from environment variables or ~/.aws/credentials.
provider "aws" {
  region = var.aws_region
}
