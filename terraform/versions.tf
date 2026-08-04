terraform {
  # Minimum Terraform version required by this configuration.
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
