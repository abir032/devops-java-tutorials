data "aws_iam_policy_document" "assume_ecs_tasks" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---------- execution role: used by ECS itself, BEFORE your code starts ----------
# pulls the image from ECR, writes logs, reads the two secrets from SSM
resource "aws_iam_role" "exec" {
  name               = "${var.project}-exec-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
}

resource "aws_iam_role_policy_attachment" "exec_managed" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "exec_secrets" {
  statement {
    sid     = "ReadTaskSecrets"
    actions = ["ssm:GetParameters"]
    resources = [
      aws_ssm_parameter.db_app_password.arn,
      aws_ssm_parameter.mq_password.arn,
    ]
  }
}

resource "aws_iam_role_policy" "exec_secrets" {
  name   = "${var.project}-exec-secrets"
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec_secrets.json
}

# ---------- task role: used by YOUR code, while it runs ----------
# Empty on purpose: Order Desk calls no AWS API (it talks to RDS, Redis and RabbitMQ directly).
resource "aws_iam_role" "task" {
  name               = "${var.project}-task-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
}
