# -----------------------------------------------------------------------------
# Common tags
# -----------------------------------------------------------------------------

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  cluster_name = "${var.project_name}-${var.environment}-eks"
}
