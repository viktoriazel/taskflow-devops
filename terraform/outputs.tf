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

output "public_subnet_id" {
  description = "ID of the public subnet (Frontend EC2, NAT Gateway)"
  value       = aws_subnet.public.id
}

output "private_app_subnet_id" {
  description = "ID of the private app subnet (Backend EC2, Worker EC2)"
  value       = aws_subnet.private_app.id
}

output "private_db_subnet_ids" {
  description = "IDs of both private DB subnets - used for the RDS DB subnet group"
  value       = [aws_subnet.private_db_1.id, aws_subnet.private_db_2.id]
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

output "sg_frontend_id" {
  description = "ID of the Frontend security group"
  value       = aws_security_group.frontend.id
}

output "sg_backend_id" {
  description = "ID of the Backend security group"
  value       = aws_security_group.backend.id
}

output "sg_worker_id" {
  description = "ID of the Worker security group"
  value       = aws_security_group.worker.id
}

output "sg_rds_id" {
  description = "ID of the RDS security group"
  value       = aws_security_group.rds.id
}

# -----------------------------------------------------------------------------
# Compute
# -----------------------------------------------------------------------------

output "frontend_public_ip" {
  description = "Public IP of the Frontend/Nginx EC2 instance"
  value       = aws_instance.frontend.public_ip
}

output "backend_private_ip" {
  description = "Private IP of the Backend EC2 instance"
  value       = aws_instance.backend.private_ip
}

output "worker_private_ip" {
  description = "Private IP of the Worker EC2 instance"
  value       = aws_instance.worker.private_ip
}

# -----------------------------------------------------------------------------
# Data layer
# -----------------------------------------------------------------------------

output "rds_endpoint" {
  description = "RDS PostgreSQL connection endpoint"
  value       = aws_db_instance.main.endpoint
}

# Populated in Steps 6-7 (s3.tf, sns.tf)

# output "s3_bucket_name" {
#   description = "Name of the S3 bucket for file uploads"
#   value       = aws_s3_bucket.main.bucket
# }
#
# output "sns_topic_arn" {
#   description = "ARN of the SNS topic for notifications"
#   value       = aws_sns_topic.main.arn
# }
