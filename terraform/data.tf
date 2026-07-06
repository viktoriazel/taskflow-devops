# Dynamically resolves available Availability Zones in the configured AWS region.
# Used to place subnets across multiple AZs without hardcoding AZ names.
data "aws_availability_zones" "available" {
  state = "available"
}
