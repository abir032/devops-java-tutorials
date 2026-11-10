resource "aws_vpc" "db" {
  cidr_block           = var.db_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-db-vpc" }
}

resource "aws_subnet" "db_a" {
  vpc_id            = aws_vpc.db.id
  cidr_block        = cidrsubnet(var.db_vpc_cidr, 8, 1)
  availability_zone = local.az_a
  tags              = { Name = "${var.project}-db-a" }
}

resource "aws_subnet" "db_b" {
  vpc_id            = aws_vpc.db.id
  cidr_block        = cidrsubnet(var.db_vpc_cidr, 8, 2)
  availability_zone = local.az_b
  tags              = { Name = "${var.project}-db-b" }
}

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.db.id
  tags   = { Name = "${var.project}-db-rt" }
}

resource "aws_route_table_association" "db_a" {
  subnet_id      = aws_subnet.db_a.id
  route_table_id = aws_route_table.db.id
}

resource "aws_route_table_association" "db_b" {
  subnet_id      = aws_subnet.db_b.id
  route_table_id = aws_route_table.db.id
}