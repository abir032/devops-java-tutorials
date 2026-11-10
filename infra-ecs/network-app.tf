
data "aws_availability_zones" "available" {

}

locals {
  az_a = data.aws_availability_zones.available.names[0]
  az_b = data.aws_availability_zones.available.names[1]
}


resource "aws_vpc" "app" {
  cidr_block           = var.app_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "${var.project}-app-vpc"
  }
}


resource "aws_internet_gateway" "app" {
  vpc_id = aws_vpc.app.id
  tags   = { Name = "${var.project}-app-igw" }
}

resource "aws_subnet" "frontend" {
  vpc_id                  = aws_vpc.app.id
  cidr_block              = cidrsubnet(var.app_vpc_cidr, 8, 1) # 10.10.1.0/24
  availability_zone       = local.az_a
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-frontend-public" }
}

resource "aws_subnet" "backend" {
  vpc_id            = aws_vpc.app.id
  cidr_block        = cidrsubnet(var.app_vpc_cidr, 8, 2) # 10.10.2.0/24
  availability_zone = local.az_a
  tags              = { Name = "${var.project}-backend-private" }
}

resource "aws_route_table" "frontend" {
  vpc_id = aws_vpc.app.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.app.id
  }
  tags = { Name = "${var.project}-frontend-rt" }
}

resource "aws_route_table_association" "frontend" {
  subnet_id      = aws_subnet.frontend.id
  route_table_id = aws_route_table.frontend.id
}

# routes are separate aws_route resources (Steps 4 and 6); never mix inline and aws_route
resource "aws_route_table" "backend" {
  vpc_id = aws_vpc.app.id
  tags   = { Name = "${var.project}-backend-rt" }
}

resource "aws_route_table_association" "backend" {
  subnet_id      = aws_subnet.backend.id
  route_table_id = aws_route_table.backend.id
}



// AZ for the ALB 

resource "aws_subnet" "frontend_b" {
  vpc_id                  = aws_vpc.app.id
  cidr_block              = cidrsubnet(var.app_vpc_cidr, 8, 3) # 10.40.3.0/24
  availability_zone       = local.az_b
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-frontend-public-b" }
}

resource "aws_route_table_association" "frontend_b" {
  subnet_id      = aws_subnet.frontend_b.id
  route_table_id = aws_route_table.frontend.id
}


resource "aws_subnet" "backend_b" {
  vpc_id            = aws_vpc.app.id
  cidr_block        = cidrsubnet(var.app_vpc_cidr, 8, 4) # 10.40.4.0/24
  availability_zone = local.az_b
  tags              = { Name = "${var.project}-backend-private-b" }
}

resource "aws_route_table_association" "backend_b" {
  subnet_id      = aws_subnet.backend_b.id
  route_table_id = aws_route_table.backend.id
}
