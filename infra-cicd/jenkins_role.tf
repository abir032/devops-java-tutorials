# ---------- IAM: what the Jenkins server (Terraform jobs) may do ----------
# The role is attached to the Jenkins EC2, so the "infra" pipeline needs no stored access keys.
# The role is named jenkins-*, NOT orderdesk-*, so the policy below never lets it edit itself:
# changes to this file must be applied from an admin workstation, not from the Jenkins job.

variable "tfstate_bucket" {
  type    = string
  default = "tutorials-tfstate-126052242757"
}

data "aws_iam_policy_document" "jenkins_terraform" {
  # remote state + lock file
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.tfstate_bucket}"]
  }
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.tfstate_bucket}/*"]
  }

  statement {
    sid       = "WhoAmI"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # the services infra-cicd and infra-ecs manage, limited to one region
  statement {
    sid = "ManagedServices"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "ecs:*",
      "ecr:*",
      "rds:*",
      "elasticache:*",
      "mq:*",
      "logs:*",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "KmsLookup"
    actions   = ["kms:DescribeKey", "kms:ListAliases"]
    resources = ["*"]
  }

  # secrets of the app (/orderdesk*) and the public Ubuntu AMI lookup
  statement {
    sid     = "SsmApp"
    actions = ["ssm:*"]
    resources = [
      "arn:aws:ssm:${var.region}:${local.account_id}:parameter/orderdesk*",
      "arn:aws:ssm:${var.region}::parameter/aws/service/*",
    ]
  }
  statement {
    sid       = "SsmDescribe"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  # IAM: read everything (Terraform refresh), write only orderdesk-* roles and profiles
  statement {
    sid       = "IamRead"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }
  statement {
    sid = "IamWriteOrderdesk"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/orderdesk-*",
      "arn:aws:iam::${local.account_id}:instance-profile/orderdesk-*",
    ]
  }
  # only the ECS execution managed policy may be attached: no AdministratorAccess
  statement {
    sid       = "IamAttachEcsExecOnly"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:aws:iam::${local.account_id}:role/orderdesk-*"]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
    }
  }
  statement {
    sid       = "IamPassOrderdesk"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/orderdesk-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com", "ecs-tasks.amazonaws.com"]
    }
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "rds.amazonaws.com",
        "elasticache.amazonaws.com",
        "mq.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "jenkins-terraform-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy" "jenkins" {
  name   = "jenkins-terraform-policy"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_terraform.json
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "jenkins-terraform-profile"
  role = aws_iam_role.jenkins.name
}

# Terraform cannot attach a profile to an EXISTING instance. One-off, no downtime:
#   aws ec2 associate-iam-instance-profile --instance-id <jenkins id> \
#     --iam-instance-profile Name=jenkins-terraform-profile
