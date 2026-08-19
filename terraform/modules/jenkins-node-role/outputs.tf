output "role_arn" {
  description = "ARN of the Jenkins node IAM role, usable only once both managed policies are attached"
  value       = aws_iam_role.this.arn

  # The whole point of this module: the ARN alone carries no dependency on the
  # attachments, so consumers could otherwise launch nodes against a role that
  # has no permissions yet. This makes anything reading role_arn wait for both.
  depends_on = [
    aws_iam_role_policy_attachment.worker,
    aws_iam_role_policy_attachment.ecr_pull,
  ]
}

output "role_name" {
  description = "Name of the Jenkins node IAM role"
  value       = aws_iam_role.this.name
}
