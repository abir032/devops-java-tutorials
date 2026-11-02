# ---------- web ----------
resource "aws_security_group" "web" {
  name        = "${var.project}-web-sg"
  description = "nginx: HTTP and SSH from my IP"
  vpc_id      = aws_vpc.app.id
  tags        = { Name = "${var.project}-web-sg" }
}
resource "aws_vpc_security_group_ingress_rule" "web_ssh" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = var.my_ip
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}
resource "aws_vpc_security_group_ingress_rule" "web_http" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = var.my_ip
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}
resource "aws_vpc_security_group_egress_rule" "web_all_out" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- nat ----------
resource "aws_security_group" "nat" {
  name        = "${var.project}-nat-sg"
  description = "NAT: forward traffic from the backend subnet"
  vpc_id      = aws_vpc.app.id
  tags        = { Name = "${var.project}-nat-sg" }
}
resource "aws_vpc_security_group_ingress_rule" "nat_from_backend" {
  security_group_id = aws_security_group.nat.id
  cidr_ipv4         = aws_subnet.backend.cidr_block
  ip_protocol       = "-1"
}
resource "aws_vpc_security_group_egress_rule" "nat_all_out" {
  security_group_id = aws_security_group.nat.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- backend ----------
resource "aws_security_group" "backend" {
  name        = "${var.project}-backend-sg"
  description = "Spring Boot: API and SSH from web only"
  vpc_id      = aws_vpc.app.id
  tags        = { Name = "${var.project}-backend-sg" }
}
resource "aws_vpc_security_group_ingress_rule" "backend_api_from_web" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}
resource "aws_vpc_security_group_ingress_rule" "backend_ssh_from_web" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}
resource "aws_vpc_security_group_egress_rule" "backend_all_out" {
  security_group_id = aws_security_group.backend.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- data tier (DB VPC): one guard per service ----------
resource "aws_security_group" "rds" {
  name        = "${var.project}-rds-sg"
  description = "MariaDB from the backend subnet"
  vpc_id      = aws_vpc.db.id
  tags        = { Name = "${var.project}-rds-sg" }
}
resource "aws_vpc_security_group_ingress_rule" "rds_from_backend" {
  security_group_id = aws_security_group.rds.id
  cidr_ipv4         = aws_subnet.backend.cidr_block
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
}

resource "aws_security_group" "redis" {
  name        = "${var.project}-redis-sg"
  description = "Redis from the backend subnet"
  vpc_id      = aws_vpc.db.id
  tags        = { Name = "${var.project}-redis-sg" }
}
resource "aws_vpc_security_group_ingress_rule" "redis_from_backend" {
  security_group_id = aws_security_group.redis.id
  cidr_ipv4         = aws_subnet.backend.cidr_block
  ip_protocol       = "tcp"
  from_port         = 6379
  to_port           = 6379
}

resource "aws_security_group" "mq" {
  name        = "${var.project}-mq-sg"
  description = "RabbitMQ AMQPS from the backend subnet"
  vpc_id      = aws_vpc.db.id
  tags        = { Name = "${var.project}-mq-sg" }
}
resource "aws_vpc_security_group_ingress_rule" "mq_from_backend" {
  security_group_id = aws_security_group.mq.id
  cidr_ipv4         = aws_subnet.backend.cidr_block
  ip_protocol       = "tcp"
  from_port         = 5671
  to_port           = 5671
}