# -----------------------------------------------------------------------------
# Security Groups
#
# All Security Groups are created without inline rules to avoid circular
# dependencies when SG rules cross-reference each other by ID.
# All ingress/egress rules are defined below as separate
# aws_security_group_rule resources.
# -----------------------------------------------------------------------------

resource "aws_security_group" "frontend" {
  name        = "${var.project_name}-${var.environment}-sg-frontend"
  description = "Frontend EC2: HTTP from internet, SSH from operator IP"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-sg-frontend"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_security_group" "backend" {
  name        = "${var.project_name}-${var.environment}-sg-backend"
  description = "Backend EC2: app traffic and SSH from Frontend only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-sg-backend"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_security_group" "worker" {
  name        = "${var.project_name}-${var.environment}-sg-worker"
  description = "Worker EC2: app traffic from Backend, SSH from Frontend (bastion)"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-sg-worker"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-sg-rds"
  description = "RDS PostgreSQL: connections from Backend only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-sg-rds"
    Project     = var.project_name
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# Frontend Security Group Rules
# -----------------------------------------------------------------------------

# Nginx is the only public entry point for all app traffic
resource "aws_security_group_rule" "frontend_http_in" {
  type              = "ingress"
  security_group_id = aws_security_group.frontend.id
  description       = "HTTP from internet (Nginx public entry point)"
  protocol          = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "frontend_ssh_in" {
  type              = "ingress"
  security_group_id = aws_security_group.frontend.id
  description       = "SSH from operator IP only"
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = [var.allowed_ssh_cidr]
}

resource "aws_security_group_rule" "frontend_egress" {
  type              = "egress"
  security_group_id = aws_security_group.frontend.id
  description       = "All outbound traffic"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# Backend Security Group Rules
# -----------------------------------------------------------------------------

resource "aws_security_group_rule" "backend_app_in" {
  type                     = "ingress"
  security_group_id        = aws_security_group.backend.id
  description              = "Flask API from Frontend"
  protocol                 = "tcp"
  from_port                = 5000
  to_port                  = 5000
  source_security_group_id = aws_security_group.frontend.id
}

# Frontend acts as SSH bastion for Backend and Worker
resource "aws_security_group_rule" "backend_ssh_in" {
  type                     = "ingress"
  security_group_id        = aws_security_group.backend.id
  description              = "SSH via Frontend bastion"
  protocol                 = "tcp"
  from_port                = 22
  to_port                  = 22
  source_security_group_id = aws_security_group.frontend.id
}

resource "aws_security_group_rule" "backend_egress" {
  type              = "egress"
  security_group_id = aws_security_group.backend.id
  description       = "All outbound traffic (to RDS, Worker, S3 and SNS via NAT)"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# Worker Security Group Rules
# -----------------------------------------------------------------------------

resource "aws_security_group_rule" "worker_app_in" {
  type                     = "ingress"
  security_group_id        = aws_security_group.worker.id
  description              = "Worker API from Backend"
  protocol                 = "tcp"
  from_port                = 6000
  to_port                  = 6000
  source_security_group_id = aws_security_group.backend.id
}

resource "aws_security_group_rule" "worker_ssh_in" {
  type                     = "ingress"
  security_group_id        = aws_security_group.worker.id
  description              = "SSH via Frontend bastion"
  protocol                 = "tcp"
  from_port                = 22
  to_port                  = 22
  source_security_group_id = aws_security_group.frontend.id
}

resource "aws_security_group_rule" "worker_egress" {
  type              = "egress"
  security_group_id = aws_security_group.worker.id
  description       = "All outbound traffic (to SNS via NAT)"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# RDS Security Group Rules
# -----------------------------------------------------------------------------

# RDS has no egress rule — it is a managed service with no outbound traffic needs
resource "aws_security_group_rule" "rds_db_in" {
  type                     = "ingress"
  security_group_id        = aws_security_group.rds.id
  description              = "PostgreSQL from Backend only"
  protocol                 = "tcp"
  from_port                = 5432
  to_port                  = 5432
  source_security_group_id = aws_security_group.backend.id
}
