# -----------------------------------------------------------------------------
# Compute - EC2 Instances
# -----------------------------------------------------------------------------

# Frontend: public-facing Nginx entry point. Public IP comes from
# map_public_ip_on_launch on aws_subnet.public - no need to set
# associate_public_ip_address here as well.
resource "aws_instance" "frontend" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.frontend.id]
  key_name               = var.key_pair_name

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-frontend-nginx"
    Project     = var.project_name
    Environment = var.environment
    Role        = "frontend"
  }
}

# Backend: private Flask API. No public IP - reachable only from Frontend
# (app traffic on 5000, SSH via bastion) per aws_security_group.backend rules.
resource "aws_instance" "backend" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private_app.id
  vpc_security_group_ids = [aws_security_group.backend.id]
  key_name               = var.key_pair_name

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-backend"
    Project     = var.project_name
    Environment = var.environment
    Role        = "backend"
  }
}

# Worker: private notification service. Reachable only from Backend
# (app traffic on 6000, SSH via bastion) per aws_security_group.worker rules.
resource "aws_instance" "worker" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private_app.id
  vpc_security_group_ids = [aws_security_group.worker.id]
  key_name               = var.key_pair_name

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-worker"
    Project     = var.project_name
    Environment = var.environment
    Role        = "worker"
  }
}
