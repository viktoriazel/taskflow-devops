# -----------------------------------------------------------------------------
# ECR - Container Image Repositories
# -----------------------------------------------------------------------------

# AES256 is already Amazon ECR's default when encryption_configuration is
# omitted; specified explicitly on each repository below so the encryption
# decision is visible in code, not because it is a stronger setting than
# default.

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}-${var.environment}-frontend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-frontend"
  })
}

resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-${var.environment}-backend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-backend"
  })
}

resource "aws_ecr_repository" "worker" {
  name                 = "${var.project_name}-${var.environment}-worker"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-worker"
  })
}
