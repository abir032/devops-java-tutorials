# ---------- Application Load Balancer: the one public address of the app ----------
resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.frontend.id, aws_subnet.frontend_b.id] # 2 AZs are required
  tags               = { Name = "${var.project}-alb" }
}

# ---------- target groups: where the ALB sends traffic ----------
resource "aws_lb_target_group" "backend" {
  name                 = "${var.project}-backend-tg"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip" # Fargate tasks register by IP
  vpc_id               = aws_vpc.app.id
  deregistration_delay = 30 # the app finishes in-flight requests within 20 s (graceful shutdown)

  health_check {
    path                = "/actuator/health/readiness" # db + redis + rabbit must be UP
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "frontend" {
  name                 = "${var.project}-frontend-tg"
  port                 = 80
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.app.id
  deregistration_delay = 30

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# ---------- listener: port 80 ----------
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  # everything that is not /api/* goes to the React app
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

# /api/* goes straight to the backend
resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}
