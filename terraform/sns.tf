# -----------------------------------------------------------------------------
# SNS - Task Event Notifications
# -----------------------------------------------------------------------------

# Encrypted at rest with the AWS-managed key alias/aws/sns. A customer-managed
# KMS key was evaluated and intentionally not adopted here: unlike the
# AWS-managed key, it would require explicit KMS permissions for the future
# Worker role plus a recurring per-key cost - complexity not justified for
# this disposable dev/learning environment. Accepted trade-off, not a false
# positive; see project Decision Register.
#trivy:ignore:AWS-0136
resource "aws_sns_topic" "main" {
  name              = "${var.project_name}-${var.environment}-notifications"
  kms_master_key_id = "alias/aws/sns"

  tags = merge(local.common_tags, {
    Name    = "${var.project_name}-${var.environment}-notifications"
    Purpose = "notifications"
  })
}
