# -----------------------------------------------------------------------------
# AWS / Region
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region where all resources will be deployed"
  type        = string
  default     = "eu-north-1"
}

# -----------------------------------------------------------------------------
# Project metadata
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Short identifier used to prefix resource names (e.g. 'taskflow')"
  type        = string
  default     = "taskflow"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.project_name))
    error_message = "project_name must be lowercase letters, digits, and hyphens only, and must not start or end with a hyphen (it is used to build the S3 bucket name)."
  }
}

variable "environment" {
  description = "Deployment environment label, used in resource tags (e.g. 'dev')"
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.environment))
    error_message = "environment must be lowercase letters, digits, and hyphens only, and must not start or end with a hyphen (it is used to build the S3 bucket name)."
  }
}

# -----------------------------------------------------------------------------
# Database
# -----------------------------------------------------------------------------

variable "db_name" {
  description = "Name of the PostgreSQL database created in RDS"
  type        = string
  default     = "todo_db"
}

variable "db_username" {
  description = "Master username for the RDS PostgreSQL instance"
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_db_subnet_1_cidr" {
  description = "CIDR block for the first private DB subnet (RDS, AZ1)"
  type        = string
  default     = "10.0.3.0/24"
}

variable "private_db_subnet_2_cidr" {
  description = "CIDR block for the second private DB subnet (RDS, AZ2)"
  type        = string
  default     = "10.0.4.0/24"
}

variable "public_subnet_1_cidr" {
  description = "CIDR block for the first public subnet (future Load Balancer, NAT Gateway, AZ1)"
  type        = string
  default     = "10.0.11.0/24"
}

variable "public_subnet_2_cidr" {
  description = "CIDR block for the second public subnet (AZ2)"
  type        = string
  default     = "10.0.12.0/24"
}

variable "private_app_subnet_1_cidr" {
  description = "CIDR block for the first private app subnet (future EKS nodes, AZ1)"
  type        = string
  default     = "10.0.13.0/24"
}

variable "private_app_subnet_2_cidr" {
  description = "CIDR block for the second private app subnet (AZ2)"
  type        = string
  default     = "10.0.14.0/24"
}
