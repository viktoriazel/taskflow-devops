# Dynamically resolves available Availability Zones in the configured AWS region.
# Used to place subnets across multiple AZs without hardcoding AZ names.
data "aws_availability_zones" "available" {
  state = "available"
}

# Current AWS account ID, used to build a globally-unique S3 bucket name
# without a separate random_id resource.
data "aws_caller_identity" "current" {}
