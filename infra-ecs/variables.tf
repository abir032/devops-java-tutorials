variable "project" {
  type    = string
  default = "orderdesk-ecs"
}
variable "region" {
  type    = string
  default = "us-east-1"
}
variable "my_ip" {
  type = string
  validation {
    condition     = can(cidrhost(var.my_ip, 0)) && endswith(var.my_ip, "/32")
    error_message = "my_ip must be a single IPv4 address ending in /32."
  }
}

variable "app_vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}
variable "db_vpc_cidr" {
  type    = string
  default = "10.50.0.0/16"
}

# ---------- added in Part 5 (ECS) ----------
variable "ecr_project" {
  description = "Prefix of the ECR repositories made by infra-cicd (orderdesk-backend, orderdesk-frontend)"
  type        = string
  default     = "orderdesk"
}

variable "desired_count" {
  description = "Tasks per service. 0 on the first apply: the pipeline scales the services up on its first deploy"
  type        = number
  default     = 0
}

variable "initial_image_tag" {
  description = "Image tag in the first task definition. Never pulled while desired_count is 0"
  type        = string
  default     = "bootstrap"
}
