terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  backend "s3" {
    bucket       = "tutorials-tfstate-126052242757" # plain text only, no variables here
    key          = "orderdesk/terraform.tfstate"    # new key = this project's own state
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}