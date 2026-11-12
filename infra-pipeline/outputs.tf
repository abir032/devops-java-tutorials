output "pipeline_name" {
  value = aws_codepipeline.main.name
}

output "pipeline_url" {
  value = "https://${var.region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.main.name}/view"
}

output "github_connection_arn" {
  value = aws_codestarconnections_connection.github.arn
}

output "connection_next_step" {
  value = "Open Developer Tools > Settings > Connections, select ${aws_codestarconnections_connection.github.name}, click 'Update pending connection' and authorize GitHub. Status must become Available."
}

output "codebuild_project" {
  value = aws_codebuild_project.build.name
}

output "artifact_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}
