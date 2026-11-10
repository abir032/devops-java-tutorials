# ---------- alb (public entry point) ----------
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "ALB: HTTP from my IP"
  vpc_id      = aws_vpc.app.id
  tags        = { Name = "${var.project}-alb-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = var.my_ip
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_all_out" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- ecs tasks (backend and frontend) ----------
resource "aws_security_group" "ecs" {
  name        = "${var.project}-ecs-sg"
  description = "ECS tasks: traffic from the ALB only"
  vpc_id      = aws_vpc.app.id
  tags        = { Name = "${var.project}-ecs-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "ecs_backend_from_alb" {
  security_group_id            = aws_security_group.ecs.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "ecs_frontend_from_alb" {
  security_group_id            = aws_security_group.ecs.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "ecs_all_out" {
  security_group_id = aws_security_group.ecs.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- nat ----------
resource "aws_security_group" "nat" {
  name        = "${var.project}-nat-sg"
  description = "NAT: forward traffic from the app VPC"
  vpc_id      = aws_vpc.app.id
  tags        = { Name = "${var.project}-nat-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "nat_from_app" {
  security_group_id = aws_security_group.nat.id
  cidr_ipv4         = var.app_vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "nat_all_out" {
  security_group_id = aws_security_group.nat.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- data tier (DB VPC): one guard per service ----------
# The rules allow the whole app VPC range, so tasks in both private subnets can connect.
resource "aws_security_group" "rds" {
  name        = "${var.project}-rds-sg"
  description = "MariaDB from the app VPC"
  vpc_id      = aws_vpc.db.id
  tags        = { Name = "${var.project}-rds-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id = aws_security_group.rds.id
  cidr_ipv4         = var.app_vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
}

resource "aws_security_group" "redis" {
  name        = "${var.project}-redis-sg"
  description = "Redis from the app VPC"
  vpc_id      = aws_vpc.db.id
  tags        = { Name = "${var.project}-redis-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_app" {
  security_group_id = aws_security_group.redis.id
  cidr_ipv4         = var.app_vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 6379
  to_port           = 6379
}

resource "aws_security_group" "mq" {
  name        = "${var.project}-mq-sg"
  description = "RabbitMQ AMQPS from the app VPC"
  vpc_id      = aws_vpc.db.id
  tags        = { Name = "${var.project}-mq-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "mq_from_app" {
  security_group_id = aws_security_group.mq.id
  cidr_ipv4         = var.app_vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 5671
  to_port           = 5671
}