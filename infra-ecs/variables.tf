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