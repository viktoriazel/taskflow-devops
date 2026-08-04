# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpc"
  })
}

# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-igw"
  })
}

# -----------------------------------------------------------------------------
# Subnets
# -----------------------------------------------------------------------------

# Public subnets: for a future internet-facing Load Balancer, one per AZ.
# public_1 also hosts the NAT Gateway.
resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_1_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name                     = "${var.project_name}-${var.environment}-public-subnet-1"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_2_cidr
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name                     = "${var.project_name}-${var.environment}-public-subnet-2"
    "kubernetes.io/role/elb" = "1"
  })
}

# Private app subnets: for future EKS nodes and workloads, one per AZ.
# Outbound internet access via NAT Gateway (for S3 and SNS API calls).
resource "aws_subnet" "private_app_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_app_subnet_1_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.common_tags, {
    Name                              = "${var.project_name}-${var.environment}-private-app-subnet-1"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_subnet" "private_app_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_app_subnet_2_cidr
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = merge(local.common_tags, {
    Name                              = "${var.project_name}-${var.environment}-private-app-subnet-2"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# Private DB subnet 1 (AZ1): part of the RDS DB subnet group.
# AWS requires a DB subnet group to span at least two Availability Zones.
resource "aws_subnet" "private_db_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_db_subnet_1_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-private-db-subnet-1"
  })
}

# Private DB subnet 2 (AZ2): second AZ required for the RDS DB subnet group.
resource "aws_subnet" "private_db_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_db_subnet_2_cidr
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-private-db-subnet-2"
  })
}

# -----------------------------------------------------------------------------
# NAT Gateway
# NOTE: NAT Gateway is a billable resource (~$32/month + data transfer costs).
# Run `terraform destroy` after the project review to avoid ongoing charges.
# -----------------------------------------------------------------------------

resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-nat-eip"
  })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_1.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-nat-gateway"
  })
}

# -----------------------------------------------------------------------------
# Route Tables
# -----------------------------------------------------------------------------

# Public route table: internet-bound traffic goes through the Internet Gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-public-rt"
  })
}

# Private app route table: Backend and Worker route outbound traffic through
# the NAT Gateway so they can reach S3 and SNS without a public IP.
resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-private-app-rt"
  })
}

# Private DB route table: no default route — RDS subnets are fully isolated
# from the internet. Only the implicit local VPC route applies.
resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-private-db-rt"
  })
}

# -----------------------------------------------------------------------------
# Route Table Associations
# -----------------------------------------------------------------------------

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_app_1" {
  subnet_id      = aws_subnet.private_app_1.id
  route_table_id = aws_route_table.private_app.id
}

resource "aws_route_table_association" "private_app_2" {
  subnet_id      = aws_subnet.private_app_2.id
  route_table_id = aws_route_table.private_app.id
}

resource "aws_route_table_association" "private_db_1" {
  subnet_id      = aws_subnet.private_db_1.id
  route_table_id = aws_route_table.private_db.id
}

resource "aws_route_table_association" "private_db_2" {
  subnet_id      = aws_subnet.private_db_2.id
  route_table_id = aws_route_table.private_db.id
}

# -----------------------------------------------------------------------------
# VPC Endpoints
# -----------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_app.id]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-s3-endpoint"
  })
}
