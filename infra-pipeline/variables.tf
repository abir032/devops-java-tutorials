variable "project" {
  description = "Prefix of every resource in this stack"
  type        = string
  default     = "orderdesk-pipeline"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "github_repo" {
  description = "owner/name of the repository that holds the code"
  type        = string
  default     = "abir032/devops-java-tutorials"
}

variable "github_branch" {
  type    = string
  default = "main"
}

# ---------- what the pipeline deploys into (created by infra-cicd and infra-ecs, only READ here) ----------
variable "ecr_project" {
  description = "Prefix of the ECR repositories made by infra-cicd (orderdesk-backend, orderdesk-frontend)"
  type        = string
  default     = "orderdesk"
}

variable "ecs_cluster_name" {
  type    = string
  default = "orderdesk-ecs-cluster"
}

variable "ecs_role_prefix" {
  description = "Name prefix of the ECS execution and task roles made by infra-ecs"
  type        = string
  default     = "orderdesk-ecs"
}

variable "require_approval" {
  description = "Add a manual approval stage before the deploy"
  type        = bool
  default     = true
}

variable "approval_email" {
  description = "Optional. Gets an email when an approval is waiting. Empty = no email (approve in the console)"
  type        = string
  default     = ""
}
