variable "project" {
  type    = string
  default = "orderdesk"
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
variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/orderdesk-key.pub"
}
variable "app_vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}
variable "db_vpc_cidr" {
  type    = string
  default = "10.30.0.0/16"
}