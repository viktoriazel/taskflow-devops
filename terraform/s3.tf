# -----------------------------------------------------------------------------
# S3 - File Uploads Bucket
# -----------------------------------------------------------------------------

locals {
  # Account ID suffix guarantees global uniqueness without a random_id resource.
  uploads_bucket_name = "${var.project_name}-${var.environment}-uploads-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "uploads" {
  bucket = local.uploads_bucket_name

  # Learning-project trade-off: allows `terraform destroy` to remove the
  # bucket even if it still contains demo upload files, without a manual
  # empty-bucket step first.
  force_destroy = true

  lifecycle {
    precondition {
      condition     = length(local.uploads_bucket_name) <= 63
      error_message = "Computed S3 bucket name '${local.uploads_bucket_name}' exceeds the 63-character S3 limit. Shorten project_name or environment."
    }
  }

  tags = {
    Name        = local.uploads_bucket_name
    Project     = var.project_name
    Environment = var.environment
    Purpose     = "uploads"
  }
}

# Blocks all public access - the app reaches objects only via presigned URLs
# signed by the backend's IAM role (Step 8), never through public bucket access.
resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Disables ACLs entirely - access is controlled via IAM identity-based policy
# (Step 8), so bucket/object ACLs are never needed.
resource "aws_s3_bucket_ownership_controls" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# SSE-S3 (AWS-managed key) - no extra KMS resource or IAM permissions needed.
resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
