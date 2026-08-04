# -----------------------------------------------------------------------------
# Security Groups
#
# All Security Groups are created without inline rules to avoid circular
# dependencies when SG rules cross-reference each other by ID.
# All ingress/egress rules are defined below as separate
# aws_security_group_rule resources.
# -----------------------------------------------------------------------------

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-sg-rds"
  description = "RDS PostgreSQL security group; ingress will be added in the future EKS phase"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-sg-rds"
    Role = "database"
  })
}

# -----------------------------------------------------------------------------
# RDS Security Group Rules
# -----------------------------------------------------------------------------

# No ingress or egress rules are defined. Access from future EKS workloads
# will be added explicitly during the EKS phase.
