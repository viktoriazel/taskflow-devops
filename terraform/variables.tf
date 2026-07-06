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
  description = "Deployment environment label, used in resource tags (e.g. 'part-b')"
  type        = string
  default     = "part-b"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.environment))
    error_message = "environment must be lowercase letters, digits, and hyphens only, and must not start or end with a hyphen (it is used to build the S3 bucket name)."
  }
}

# -----------------------------------------------------------------------------
# Compute
# -----------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type for Frontend, Backend, and Worker instances"
  type        = string
  default     = "t3.micro"
}

variable "key_pair_name" {
  description = "Name of an existing EC2 Key Pair used for SSH access to instances"
  type        = string
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

variable "db_password" {
  description = "Master password for the RDS PostgreSQL instance"
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "db_password_wo_version" {
  description = "Version counter for db_password (write-only). Increment this value whenever the RDS master password needs to be rotated - changing db_password alone does not trigger an update."
  type        = number
  default     = 1
}

# -----------------------------------------------------------------------------
# Notifications
# -----------------------------------------------------------------------------

variable "notification_email" {
  description = "Email address that will receive SNS notifications for task events"
  type        = string

  validation {
    # Lightweight sanity check only - not a full RFC5322 validator. Just
    # catches obvious mistakes (empty value, spaces, missing @ or domain).
    condition     = can(regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", var.notification_email))
    error_message = "notification_email must look like a valid email address (e.g. 'you@example.com')."
  }
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (Frontend EC2, NAT Gateway)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_app_subnet_cidr" {
  description = "CIDR block for the private app subnet (Backend EC2, Worker EC2)"
  type        = string
  default     = "10.0.2.0/24"
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

# -----------------------------------------------------------------------------
# Security
# -----------------------------------------------------------------------------

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH into the frontend (public) instance, e.g. '203.0.113.10/32'"
  type        = string
}
