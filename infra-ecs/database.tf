resource "random_password" "db_master" {
  length  = 24
  special = false
}
resource "random_password" "db_app" {
  length  = 24
  special = false
}
resource "random_password" "mq" {
  length  = 24 # Amazon MQ needs at least 12 characters
  special = false
}

# ---------- RDS MariaDB ----------
resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnets"
  subnet_ids = [aws_subnet.db_a.id, aws_subnet.db_b.id]
}

resource "aws_db_instance" "main" {
  identifier     = "${var.project}-db"
  engine         = "mariadb"
  engine_version = "11.4" # compose uses 11.8; check what RDS offers, see the check below
  instance_class = "db.t4g.micro"

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "orderdesk" # Flyway creates the tables inside this empty database
  username = "orderdesk" # the app logs in as the RDS master user (simple; see the hardening note in the guide)
  password = random_password.db_app.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}

# ---------- ElastiCache (Redis) ----------
resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project}-redis-subnets"
  subnet_ids = [aws_subnet.db_a.id, aws_subnet.db_b.id]
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${var.project}-redis"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = "cache.t4g.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]
}

# ---------- Amazon MQ (RabbitMQ) ----------
resource "aws_mq_broker" "main" {
  broker_name                = "${var.project}-mq"
  engine_type                = "RabbitMQ"
  engine_version             = "4.2"
  host_instance_type         = "mq.m7g.medium" # smallest type RabbitMQ 4.x supports; t3.micro is ActiveMQ only
  deployment_mode            = "SINGLE_INSTANCE"
  publicly_accessible        = false
  subnet_ids                 = [aws_subnet.db_a.id]
  security_groups            = [aws_security_group.mq.id]
  apply_immediately          = true
  auto_minor_version_upgrade = true

  user {
    username = "orderdesk" # "guest" is not allowed on Amazon MQ
    password = random_password.mq.result
  }
}

locals {
  # endpoints[0] looks like amqps://b-xxxx.mq.us-east-1.amazonaws.com:5671
  mq_host = split(":", trimprefix(aws_mq_broker.main.instances[0].endpoints[0], "amqps://"))[0]
}

# ---------- Config for the backends (master password is NOT stored here) ----------
resource "aws_ssm_parameter" "db_endpoint" {
  name  = "/${var.project}/db/endpoint"
  type  = "String"
  value = aws_db_instance.main.address
}
resource "aws_ssm_parameter" "db_app_password" {
  name  = "/${var.project}/db/app_password"
  type  = "SecureString"
  value = random_password.db_app.result
}
resource "aws_ssm_parameter" "redis_endpoint" {
  name  = "/${var.project}/redis/endpoint"
  type  = "String"
  value = aws_elasticache_cluster.redis.cache_nodes[0].address
}
resource "aws_ssm_parameter" "mq_endpoint" {
  name  = "/${var.project}/mq/endpoint"
  type  = "String"
  value = local.mq_host
}
resource "aws_ssm_parameter" "mq_password" {
  name  = "/${var.project}/mq/password"
  type  = "SecureString"
  value = random_password.mq.result
}