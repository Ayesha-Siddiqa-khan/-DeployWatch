
# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name                   = "deploywatch-vpc"
    Project                = var.project_name
    TerraPilotProject      = var.project_name
    TerraPilotResourceType = "vpc"
    Environment            = var.environment
    ManagedBy              = "TerraPilot"
    CostSensitive          = "false"
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name                   = "${local.resource_prefix}-public-${count.index + 1}"
    Tier                   = "public"
    Project                = var.project_name
    TerraPilotProject      = var.project_name
    TerraPilotResourceType = "public-subnet"
    Environment            = var.environment
    ManagedBy              = "TerraPilot"
    CostSensitive          = "false"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name                   = "${local.resource_prefix}-igw"
    Project                = var.project_name
    TerraPilotProject      = var.project_name
    TerraPilotResourceType = "internet-gateway"
    Environment            = var.environment
    ManagedBy              = "TerraPilot"
    CostSensitive          = "false"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name                   = "${local.resource_prefix}-public-rt"
    Project                = var.project_name
    TerraPilotProject      = var.project_name
    TerraPilotResourceType = "public-route-table"
    Environment            = var.environment
    ManagedBy              = "TerraPilot"
    CostSensitive          = "false"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}


resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                   = "${local.resource_prefix}-private-${count.index + 1}"
    Tier                   = "private"
    Project                = var.project_name
    TerraPilotProject      = var.project_name
    TerraPilotResourceType = "private-subnet"
    Environment            = var.environment
    ManagedBy              = "TerraPilot"
    CostSensitive          = "false"
  }
}

resource "aws_eip" "nat" {
  count  = 1
  domain = "vpc"

  tags = {
    Name                   = "${var.project_name}-nat-eip-${count.index + 1}"
    Project                = var.project_name
    TerraPilotProject      = var.project_name
    TerraPilotResourceType = "elastic-ip"
    Environment            = var.environment
    ManagedBy              = "TerraPilot"
    CostSensitive          = "true"
  }
}

resource "aws_nat_gateway" "main" {
  count         = 1
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name                   = "${var.project_name}-nat-${count.index + 1}"
    Project                = var.project_name
    TerraPilotProject      = var.project_name
    TerraPilotResourceType = "nat-gateway"
    Environment            = var.environment
    ManagedBy              = "TerraPilot"
    CostSensitive          = "true"
  }

  depends_on = [aws_internet_gateway.main]
}


resource "aws_route_table" "private" {
  count  = 1
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[0].id
  }


  tags = {
    Name                   = "${local.resource_prefix}-private-rt-${count.index + 1}"
    Project                = var.project_name
    TerraPilotProject      = var.project_name
    TerraPilotResourceType = "private-route-table"
    Environment            = var.environment
    ManagedBy              = "TerraPilot"
    CostSensitive          = "false"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

locals {
  public_subnet_ids  = aws_subnet.public[*].id
  private_subnet_ids = aws_subnet.private[*].id
}
