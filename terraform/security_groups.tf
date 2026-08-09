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

# Only the EKS worker node security group may reach PostgreSQL. No CIDR-based
# ingress (not VPC CIDR, not subnet CIDR, not 0.0.0.0/0) and no egress rules -
# RDS never initiates outbound connections, and Security Groups are stateful,
# so response traffic for allowed inbound connections is permitted automatically.
resource "aws_vpc_security_group_ingress_rule" "rds_from_eks_nodes" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = module.eks.node_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from EKS worker nodes"
}
