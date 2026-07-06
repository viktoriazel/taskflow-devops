# -----------------------------------------------------------------------------
# SNS - Task Event Notifications
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "main" {
  name = "${var.project_name}-${var.environment}-notifications"

  tags = {
    Name        = "${var.project_name}-${var.environment}-notifications"
    Project     = var.project_name
    Environment = var.environment
    Purpose     = "notifications"
  }
}

# Email subscriptions start in PendingConfirmation until the recipient confirms
# the subscription using the link/token AWS sends after apply. Terraform can
# create the subscription request, but recipient confirmation is still required.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.main.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
