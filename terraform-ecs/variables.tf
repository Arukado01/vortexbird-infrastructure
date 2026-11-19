variable "environment" {
  type = string
  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "Select development, staging or production."
  }
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "vpc_cidr" {
  type = string
  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 8, 21))
    error_message = "Provide an IPv4 network that supports the application subnet layout."
  }
}

variable "deploy_services" {
  description = "Enable only after images, migrations, secrets, identity and TLS are ready."
  type        = bool
  default     = false
}

variable "certificate_arn" {
  type    = string
  default = null
}

variable "portal_origin" {
  type    = string
  default = null
  validation {
    condition     = var.portal_origin == null ? true : can(regex("^https://[A-Za-z0-9.-]+$", var.portal_origin))
    error_message = "Use an HTTPS origin without path or trailing slash."
  }
}

variable "keycloak_url" {
  type    = string
  default = null
  validation {
    condition     = var.keycloak_url == null ? true : can(regex("^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]+)?$", var.keycloak_url)) && !endswith(var.keycloak_url, "/")
    error_message = "Use the public HTTPS Keycloak URL without trailing slash."
  }
}

variable "image_digests" {
  description = "Immutable image digests published in the stack ECR repositories."
  type = object({
    frontend = string
    backend  = string
  })
  default = null
  validation {
    condition     = var.image_digests == null ? true : alltrue([for digest in [var.image_digests.frontend, var.image_digests.backend] : can(regex("^sha256:[0-9a-f]{64}$", digest))])
    error_message = "Use immutable sha256 image digests."
  }
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "redis_user_group_id" {
  description = "External Redis ACL user group with password authentication. Null disables cache."
  type        = string
  default     = null
}

variable "redis_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "secrets_kms_key_arn" {
  type    = string
  default = null
}

variable "migration_runtime_roles" {
  description = "Existing limited PostgreSQL login roles; the migration job grants only the runtime privileges they require."
  type        = list(string)
  default     = ["vortexbird_api", "vortexbird_worker"]
  validation {
    condition = length(var.migration_runtime_roles) > 0 && length(var.migration_runtime_roles) <= 8 && alltrue([
      for role in var.migration_runtime_roles : can(regex("^[a-z_][a-z0-9_]{0,62}$", role))
    ])
    error_message = "Supply 1-8 existing PostgreSQL role names using lowercase identifiers."
  }
}
