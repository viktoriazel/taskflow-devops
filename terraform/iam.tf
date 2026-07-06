# -----------------------------------------------------------------------------
# IAM - Backend (S3) and Worker (SNS) instance roles
#
# Scoped to exactly what the application code calls (verified against
# backend/app.py and worker/worker.py) - no ListBucket, no DeleteObject, no
# broader SNS actions, no Frontend role (Frontend never touches the AWS SDK).
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Backend: S3 access for file uploads/downloads
# -----------------------------------------------------------------------------

resource "aws_iam_role" "backend" {
  name = "${var.project_name}-${var.environment}-backend-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-${var.environment}-backend-role"
    Project     = var.project_name
    Environment = var.environment
    Role        = "backend"
  }
}

# Object-level actions only, scoped to the uploads bucket's objects - matches
# backend/app.py exactly: upload_fileobj() (PutObject, plus
# AbortMultipartUpload since 30MB uploads can exceed s3transfer's 8MB
# multipart threshold) and generate_presigned_url("get_object") (GetObject).
# No ListBucket (no list_objects call), no DeleteObject (delete_todo only
# removes the DB row, never calls delete_object).
resource "aws_iam_role_policy" "backend_s3" {
  name = "${var.project_name}-${var.environment}-backend-s3-policy"
  role = aws_iam_role.backend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:AbortMultipartUpload",
        ]
        Resource = "${aws_s3_bucket.uploads.arn}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "backend" {
  name = "${var.project_name}-${var.environment}-backend-profile"
  role = aws_iam_role.backend.name

  tags = {
    Name        = "${var.project_name}-${var.environment}-backend-profile"
    Project     = var.project_name
    Environment = var.environment
    Role        = "backend"
  }
}

# -----------------------------------------------------------------------------
# Worker: SNS publish for task notifications
# -----------------------------------------------------------------------------

resource "aws_iam_role" "worker" {
  name = "${var.project_name}-${var.environment}-worker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-${var.environment}-worker-role"
    Project     = var.project_name
    Environment = var.environment
    Role        = "worker"
  }
}

# sns:Publish only, scoped to the notifications topic - matches worker.py
# exactly: sns_client.publish() is the only SNS call in the code.
resource "aws_iam_role_policy" "worker_sns" {
  name = "${var.project_name}-${var.environment}-worker-sns-policy"
  role = aws_iam_role.worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.main.arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "worker" {
  name = "${var.project_name}-${var.environment}-worker-profile"
  role = aws_iam_role.worker.name

  tags = {
    Name        = "${var.project_name}-${var.environment}-worker-profile"
    Project     = var.project_name
    Environment = var.environment
    Role        = "worker"
  }
}
