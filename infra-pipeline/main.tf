data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  ecs_arn    = "arn:aws:ecs:${var.region}:${local.account_id}"
}

# Read-only lookups. They fail early with a clear message if infra-cicd is not applied.
data "aws_ecr_repository" "backend" {
  name = "${var.ecr_project}-backend"
}

data "aws_ecr_repository" "frontend" {
  name = "${var.ecr_project}-frontend"
}

# ---------- GitHub connection ----------
# Created as PENDING. Authorize it once in the console (see the connection_next_step output).
resource "aws_codestarconnections_connection" "github" {
  name          = "${var.project}-github"
  provider_type = "GitHub"
}

# ---------- artifact bucket: files handed from stage to stage ----------
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.project}-artifacts-${local.account_id}"
  force_destroy = true # practice setup: destroy works even with artifacts inside
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"
    filter {}
    expiration { days = 14 }
  }
}

# ---------- approval notification (optional) ----------
resource "aws_sns_topic" "approval" {
  count = var.require_approval && var.approval_email != "" ? 1 : 0
  name  = "${var.project}-approval"
}

resource "aws_sns_topic_subscription" "approval_email" {
  count     = length(aws_sns_topic.approval)
  topic_arn = aws_sns_topic.approval[0].arn
  protocol  = "email"
  endpoint  = var.approval_email
}

# ---------- CodeBuild: test, build and push the images ----------
data "aws_iam_policy_document" "assume_codebuild" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_group" "build" {
  name              = "/aws/codebuild/${var.project}-build"
  retention_in_days = 14
}

resource "aws_iam_role" "build" {
  name               = "${var.project}-build-role"
  assume_role_policy = data.aws_iam_policy_document.assume_codebuild.json
}

data "aws_iam_policy_document" "build" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.build.arn}:*"]
  }

  statement {
    sid       = "Artifacts"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
    ]
    resources = [data.aws_ecr_repository.backend.arn, data.aws_ecr_repository.frontend.arn]
  }
}

resource "aws_iam_role_policy" "build" {
  name   = "${var.project}-build-policy"
  role   = aws_iam_role.build.id
  policy = data.aws_iam_policy_document.build.json
}

resource "aws_codebuild_project" "build" {
  name         = "${var.project}-build"
  service_role = aws_iam_role.build.arn

  source {
    type = "CODEPIPELINE" # the pipeline hands over the code; buildspec.yml is read from its root
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required for "docker build" inside CodeBuild
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.build.name
    }
  }
}

# ---------- CodePipeline ----------
data "aws_iam_policy_document" "assume_codepipeline" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "${var.project}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_codepipeline.json
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid       = "Artifacts"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning", "s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "UseGithubConnection"
    actions   = ["codestar-connections:UseConnection"]
    resources = [aws_codestarconnections_connection.github.arn]
  }

  statement {
    sid       = "RunBuild"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.build.arn]
  }

  statement {
    sid = "EcsDeployRead"
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:RegisterTaskDefinition", # cannot be limited to a resource
    ]
    resources = ["*"]
  }

  statement {
    sid       = "EcsUpdateService"
    actions   = ["ecs:UpdateService", "ecs:TagResource"]
    resources = ["${local.ecs_arn}:service/${var.ecs_cluster_name}/*"]
  }

  # the deploy action tags the task definition revision it registers
  statement {
    sid       = "EcsTagTaskDefinition"
    actions   = ["ecs:TagResource"]
    resources = ["${local.ecs_arn}:task-definition/*"]
  }

  statement {
    sid       = "PassEcsRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.ecs_role_prefix}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  dynamic "statement" {
    for_each = aws_sns_topic.approval
    content {
      sid       = "ApprovalNotify"
      actions   = ["sns:Publish"]
      resources = [statement.value.arn]
    }
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "${var.project}-policy"
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

resource "aws_codepipeline" "main" {
  name           = var.project
  role_arn       = aws_iam_role.pipeline.arn
  pipeline_type  = "V2"
  execution_mode = "QUEUED" # deploys run one after another, never overlapping

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.artifacts.bucket
  }

  stage {
    name = "Source"
    action {
      name             = "GitHub"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source"]
      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repo
        BranchName       = var.github_branch
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name            = "BuildAndPush"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source"]
      # names must match the secondary-artifacts identifiers in buildspec.yml
      output_artifacts = ["backend_out", "frontend_out"]
      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  dynamic "stage" {
    for_each = var.require_approval ? [1] : []
    content {
      name = "Approve"
      action {
        name     = "ApproveDeploy"
        category = "Approval"
        owner    = "AWS"
        provider = "Manual"
        version  = "1"
        configuration = merge(
          { CustomData = "Deploy this build to ECS?" },
          length(aws_sns_topic.approval) > 0 ? { NotificationArn = aws_sns_topic.approval[0].arn } : {}
        )
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name            = "DeployBackend"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["backend_out"]
      run_order       = 1
      configuration = {
        ClusterName       = var.ecs_cluster_name
        ServiceName       = "backend"
        FileName          = "imagedefinitions.json"
        DeploymentTimeout = "15"
      }
    }
    action {
      name            = "DeployFrontend"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["frontend_out"]
      run_order       = 1
      configuration = {
        ClusterName       = var.ecs_cluster_name
        ServiceName       = "frontend"
        FileName          = "imagedefinitions.json"
        DeploymentTimeout = "15"
      }
    }
  }
}
