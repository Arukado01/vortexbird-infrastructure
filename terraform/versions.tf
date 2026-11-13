terraform {

backend "s3" {

}
required_version = ">= 1.10, < 2.0"
required_providers {
aws = { source = "hashicorp/aws", version = "~> 6.0" }
tls = { source = "hashicorp/tls", version = "~> 4.0" }
}
# Configure an EXISTING encrypted, versioned S3 state bucket with -backend-config.
# No backend is provisioned automatically and no state must enter Git.
}
provider "aws" {
region = var.region
default_tags {
tags = { Project = "VortexBird", Environment = var.environment, ManagedBy = "Terraform" }
}
}
data "aws_caller_identity" "current" {

}
data "aws_availability_zones" "available" {
state = "available" 
}
locals {
name = "vortexbird-${var.environment}"
production = var.environment == "production"
azs = slice(data.aws_availability_zones.available.names, 0, 2)
nat_count = local.production ? 2 : 1
}

