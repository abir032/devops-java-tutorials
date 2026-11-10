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
  default = "vpc-xxxxxxxx" # <-- yours
}

variable "jenkins_subnet_id" {
  type    = string
  default = "subnet-xxxxxxxx" # <-- yours
}

variable "jenkins_security_group_id" {
  type    = string
  default = "sg-xxxxxxxx" # <-- yours
}

variable "key_name" {
  description = "Name of an EXISTING EC2 key pair, for admin SSH"
  type        = string
  default     = "your-key-name" # <-- yours
}

variable "controller_public_key" {
  description = "The .pub line made on the Jenkins server (build-agent-key.pub)"
  type        = string
  default     = "ssh-ed25519 AAAA... jenkins controller to build-agent" # <-- yours
}

variable "agent_instance_type" {
  type    = string
  default = "t3.medium"
}

# Must match what infra-ecs creates: "<project>-cluster" with project orderdesk-ecs
variable "ecs_cluster_name" {
  type    = string
  default = "orderdesk-ecs-cluster"
}
