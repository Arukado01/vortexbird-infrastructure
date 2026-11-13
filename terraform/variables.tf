variable "region" {
type = string
default = "us-east-2" 
}
variable "environment" {
type = string
validation {
condition = contains(["demo", "production"], var.environment)
error_message = "Choose demo or production."
}
}
variable "kubernetes_version" {
type = string
description = "Select a currently standard-supported EKS version after aws eks describe-cluster-versions."
}
variable "admin_role_arn" {
type = string
description = "Existing IAM role permitted to administer this new EKS cluster." 
}
variable "eks_public_access_cidrs" {
type = list(string)
description = "Administrator/VPN public egress CIDRs; never 0.0.0.0/0."
validation {
condition = length(var.eks_public_access_cidrs) > 0 && !contains(var.eks_public_access_cidrs, "0.0.0.0/0")
error_message = "Provide explicit administrator network CIDRs."
}
}
variable "node_instance_types" {
type = list(string)
default = ["t3.large"] 
}
variable "db_instance_class" {
type = string
default = "db.t4g.micro" 
}
variable "redis_node_type" {
type = string
default = "cache.t4g.micro" 
}
variable "redis_auth_token" {
type = string
sensitive = true
description = "Set from a secure environment variable, never tfvars in Git. Terraform state contains this secret."
validation {
condition = length(var.redis_auth_token) >= 32
error_message = "Use a random Redis token of at least 32 characters."
}
}
variable "alarm_email" {
type = string
default = ""
description = "Optional explicitly approved alert destination; SNS subscription requires confirmation." 
}
variable "github_oidc_provider_arn" {
type = string
default = ""
description = "Existing token.actions.githubusercontent.com provider ARN; no duplicate provider is created." 
}
variable "github_repository" {
type = string
default = ""
description = "Exact OWNER/REPO for this infrastructure repository, only after creation." 
}
variable "enable_github_role" {
type = bool
default = false 
}
