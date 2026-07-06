# Dynamically resolves available Availability Zones in the configured AWS region.
# Used to place subnets across multiple AZs without hardcoding AZ names.
data "aws_availability_zones" "available" {
  state = "available"
}

# Official Canonical Ubuntu 22.04 LTS (jammy) AMI, amd64/x86_64 - compatible
# with t3.micro. Resolved dynamically so the AMI stays current and the
# configuration works across regions without hardcoding an AMI ID.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Current AWS account ID, used to build a globally-unique S3 bucket name
# without a separate random_id resource.
data "aws_caller_identity" "current" {}
