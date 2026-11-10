data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# ---------- IAM: what the build agent may do ----------
data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent" {
  name               = "${var.project}-build-agent-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

data "aws_iam_policy_document" "agent" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]
    resources = [for r in aws_ecr_repository.app : r.arn]
  }

  statement {
    sid = "EcsDeployRead"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
      "ecs:DescribeClusters",
      "ecs:DescribeServices",
      "ecs:ListTasks",
      "ecs:DescribeTasks",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTargetGroups",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "EcsUpdateService"
    actions   = ["ecs:UpdateService"]
    resources = ["arn:aws:ecs:${var.region}:${local.account_id}:service/${var.ecs_cluster_name}/*"]
  }

  statement {
    sid       = "PassEcsRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-ecs-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "agent" {
  name   = "${var.project}-build-agent-policy"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent.json
}

resource "aws_iam_instance_profile" "agent" {
  name = "${var.project}-build-agent-profile"
  role = aws_iam_role.agent.name
}

# ---------- network guard: SSH from the Jenkins server only ----------
resource "aws_security_group" "agent" {
  name        = "${var.project}-build-agent-sg"
  description = "Build agent: SSH from the Jenkins server only"
  vpc_id      = var.jenkins_vpc_id
  tags        = { Name = "${var.project}-build-agent-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "agent_ssh" {
  security_group_id            = aws_security_group.agent.id
  referenced_security_group_id = var.jenkins_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

resource "aws_vpc_security_group_egress_rule" "agent_all_out" {
  security_group_id = aws_security_group.agent.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- the agent EC2 ----------
resource "aws_instance" "agent" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.agent_instance_type
  subnet_id                   = var.jenkins_subnet_id
  vpc_security_group_ids      = [aws_security_group.agent.id]
  associate_public_ip_address = true # outbound only (apt, Docker Hub, ECR); the SG allows no inbound from the internet
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.agent.name

  user_data = templatefile("${path.module}/agent_user_data.sh.tftpl", {
    controller_public_key = var.controller_public_key
  })
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # 2: containers on this host can also use the instance role
  }

  lifecycle { ignore_changes = [ami] }
  tags = { Name = "${var.project}-build-agent" }
}
