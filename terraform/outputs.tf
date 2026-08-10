# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

output "aws_region" {
  description = "AWS region where resources are deployed"
  value       = var.aws_region
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets for future internet-facing load balancing"
  value = [
    aws_subnet.public_1.id,
    aws_subnet.public_2.id
  ]
}

output "private_app_subnet_ids" {
  description = "IDs of the private application subnets for future EKS workloads"
  value = [
    aws_subnet.private_app_1.id,
    aws_subnet.private_app_2.id
  ]
}

output "private_db_subnet_ids" {
  description = "IDs of both private DB subnets - used for the RDS DB subnet group"
  value       = [aws_subnet.private_db_1.id, aws_subnet.private_db_2.id]
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

output "sg_rds_id" {
  description = "ID of the RDS security group"
  value       = aws_security_group.rds.id
}

# -----------------------------------------------------------------------------
# Data layer
# -----------------------------------------------------------------------------

output "rds_address" {
  description = "Hostname of the private RDS PostgreSQL instance"
  value       = aws_db_instance.main.address
}

output "rds_master_user_secret_arn" {
  description = "ARN pointer to the RDS-managed master secret; this is not the secret value and remains stored in Terraform state"
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
  sensitive   = true
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket for file uploads"
  value       = aws_s3_bucket.uploads.bucket
}

output "s3_bucket_arn" {
  description = "ARN of the private uploads S3 bucket"
  value       = aws_s3_bucket.uploads.arn
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic for notifications"
  value       = aws_sns_topic.main.arn
}

# -----------------------------------------------------------------------------
# Container Registry
# -----------------------------------------------------------------------------

output "frontend_ecr_repository_url" {
  description = "URL of the Frontend ECR repository, for future image pushes"
  value       = aws_ecr_repository.frontend.repository_url
}

output "backend_ecr_repository_url" {
  description = "URL of the Backend ECR repository, for future image pushes"
  value       = aws_ecr_repository.backend.repository_url
}

output "worker_ecr_repository_url" {
  description = "URL of the Worker ECR repository, for future image pushes"
  value       = aws_ecr_repository.worker.repository_url
}

# -----------------------------------------------------------------------------
# EKS
# -----------------------------------------------------------------------------

output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "Kubernetes API server endpoint for the EKS cluster"
  value       = module.eks.cluster_endpoint
}

output "eks_oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider, for future Backend/Worker IRSA role trust policies"
  value       = module.eks.oidc_provider_arn
}

output "aws_load_balancer_controller_role_arn" {
  description = "ARN of the dedicated EKS Pod Identity role for the AWS Load Balancer Controller"
  value       = aws_iam_role.lb_controller_pod_identity.arn
}
