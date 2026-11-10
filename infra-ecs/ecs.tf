# The ECR repositories are made by infra-cicd, so apply that stack first.
data "aws_ecr_repository" "backend" {
  name = "${var.ecr_project}-backend"
}

data "aws_ecr_repository" "frontend" {
  name = "${var.ecr_project}-frontend"
}

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project}"
  retention_in_days = 7
}

# ---------- backend: Spring Boot ----------
resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.project}-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name         = "backend"
    image        = "${data.aws_ecr_repository.backend.repository_url}:${var.initial_image_tag}"
    essential    = true
    portMappings = [{ containerPort = 8080, protocol = "tcp" }]

    # same variables as docker-compose / the EC2 setup (Spring "relaxed binding")
    environment = [
      { name = "SPRING_DATASOURCE_URL", value = "jdbc:mariadb://${aws_db_instance.main.address}:3306/orderdesk" },
      { name = "SPRING_DATASOURCE_USERNAME", value = aws_db_instance.main.username },
      { name = "SPRING_DATA_REDIS_HOST", value = aws_elasticache_cluster.redis.cache_nodes[0].address },
      { name = "SPRING_RABBITMQ_HOST", value = local.mq_host },
      { name = "SPRING_RABBITMQ_PORT", value = "5671" },
      { name = "SPRING_RABBITMQ_SSL_ENABLED", value = "true" },
      { name = "SPRING_RABBITMQ_USERNAME", value = "orderdesk" },
      { name = "JAVA_TOOL_OPTIONS", value = "-XX:MaxRAMPercentage=70" },
    ]

    # secrets are read from SSM by the EXECUTION role when the task starts
    secrets = [
      { name = "SPRING_DATASOURCE_PASSWORD", valueFrom = aws_ssm_parameter.db_app_password.arn },
      { name = "SPRING_RABBITMQ_PASSWORD", valueFrom = aws_ssm_parameter.mq_password.arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "backend"
      }
    }
  }])
}

resource "aws_ecs_service" "backend" {
  name            = "backend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  health_check_grace_period_seconds  = 180 # Spring Boot + Flyway need time before the first health check counts
  deployment_minimum_healthy_percent = 100 # rolling deploy: never fewer healthy tasks than desired
  deployment_maximum_percent         = 200 # ... by starting new tasks before stopping old ones

  deployment_circuit_breaker {
    enable   = true
    rollback = true # a deployment whose tasks keep failing is rolled back automatically
  }

  network_configuration {
    subnets          = [aws_subnet.backend.id, aws_subnet.backend_b.id]
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "backend"
    container_port   = 8080
  }

  # the target group must be attached to the ALB (listener rule) before the service uses it,
  # and the private subnets need the NAT route to pull images
  depends_on = [aws_lb_listener_rule.api, aws_route.backend_default]

  # Jenkins deploys new task definition revisions and sets the task count.
  # Without this, the next "terraform apply" would undo the last deployment.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

# ---------- frontend: nginx + the React build ----------
resource "aws_ecs_task_definition" "frontend" {
  family                   = "${var.project}-frontend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name         = "frontend"
    image        = "${data.aws_ecr_repository.frontend.repository_url}:${var.initial_image_tag}"
    essential    = true
    portMappings = [{ containerPort = 80, protocol = "tcp" }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "frontend"
      }
    }
  }])
}

resource "aws_ecs_service" "frontend" {
  name            = "frontend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.frontend.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = [aws_subnet.backend.id, aws_subnet.backend_b.id]
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = "frontend"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.http, aws_route.backend_default]

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}
