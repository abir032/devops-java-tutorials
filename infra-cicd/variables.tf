variable "project" {
  type    = string
  default = "orderdesk"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# Where Jenkins lives
variable "jenkins_vpc_id" {
  type    = string
  default = "vpc-0e371d74eef856f59"
}

variable "jenkins_subnet_id" {
  type    = string
  default = "subnet-0f9fc2b455bd591e6"
}

variable "jenkins_security_group_id" {
  type    = string
  default = "sg-067daa85f8c56042c"
}

variable "key_name" {
  description = "Name of an EXISTING EC2 key pair, for admin SSH"
  type        = string
  default     = "sandox-key-pair"
}

variable "controller_public_key" {
  description = "The .pub line made on the Jenkins server (build-agent-key.pub)"
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFhM1j1nPWVd+YnPNCqE8DmiWmAvoHJps2FGXIYXkXdm jenkins controller to build-agent"
}

variable "agent_instance_type" {
  type    = string
  default = "t3.small" # free-tier eligible on this account
}

# Must match what infra-ecs creates: "<project>-cluster" with project orderdesk-ecs
variable "ecs_cluster_name" {
  type    = string
  default = "orderdesk-ecs-cluster"
}
