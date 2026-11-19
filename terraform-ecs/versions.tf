terraform {
  required_version = ">= 1.10, < 2.0"
  backend "s3" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "VortexBird", Environment = var.environment, ManagedBy = "Terraform" }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  name            = "vortexbird-ecs-${var.environment}"
  production      = var.environment == "production"
  zones           = slice(data.aws_availability_zones.available.names, 0, 2)
  nat_count       = local.production ? 2 : 1
  containers      = toset(["frontend", "api", "worker"])
  task_containers = setunion(local.containers, toset(["migration"]))
  services        = var.deploy_services ? local.containers : toset([])
}
