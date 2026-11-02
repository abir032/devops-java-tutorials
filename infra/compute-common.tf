data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_key_pair" "main" {
  key_name   = "${var.project}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  ssm_prefix = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}"
}

resource "aws_iam_role" "backend" {
  name               = "${var.project}-backend-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

data "aws_iam_policy_document" "backend" {
  statement {
    sid     = "ReadOwnParameters"
    actions = ["ssm:GetParameter"]
    resources = [
      "${local.ssm_prefix}/db/endpoint",
      "${local.ssm_prefix}/db/app_password",
      "${local.ssm_prefix}/redis/endpoint",
      "${local.ssm_prefix}/mq/endpoint",
      "${local.ssm_prefix}/mq/password",
    ]
  }
}

resource "aws_iam_role_policy" "backend" {
  name   = "${var.project}-backend-policy"
  role   = aws_iam_role.backend.id
  policy = data.aws_iam_policy_document.backend.json
}

resource "aws_iam_instance_profile" "backend" {
  name = "${var.project}-backend-profile"
  role = aws_iam_role.backend.name
}