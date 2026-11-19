variable "identity_enabled" {
  description = "Opt in to new, dedicated Keycloak infrastructure. False creates no identity resources."
  type        = bool
  default     = false
}

variable "identity_deploy_service" {
  description = "Enable only after identity database role, secrets, image, TLS and realm bootstrap procedure are reviewed."
  type        = bool
  default     = false
  validation {
    condition     = !var.identity_deploy_service || var.identity_enabled
    error_message = "identity_deploy_service requires identity_enabled."
  }
}

variable "identity_hostname" {
  description = "Owned DNS hostname for Keycloak, without scheme, path or wildcard. Use the portal hostname only with identity_shared_host."
  type        = string
  default     = null
  validation {
    condition = var.identity_hostname == null ? (
      !var.identity_deploy_service && !var.identity_manage_dns && !var.identity_request_certificate && var.identity_certificate_arn == null
    ) : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.identity_hostname))
    error_message = "Provide an owned DNS hostname to deploy Keycloak, configure identity DNS or configure its certificate."
  }
}

variable "identity_shared_host" {
  description = "Publish Keycloak under /auth on the portal's HTTPS host using its existing DNS record and listener certificate."
  type        = bool
  default     = false
  nullable    = false
  validation {
    condition = !var.identity_shared_host || (var.identity_enabled && try(
      var.portal_origin == "https://${var.identity_hostname}" && var.keycloak_url == "${var.portal_origin}/auth", false
    ))
    error_message = "Shared-host identity requires identity_enabled, the portal hostname, its HTTPS origin and keycloak_url equal to that origin plus /auth."
  }
  validation {
    condition     = !var.identity_shared_host || (!var.identity_manage_dns && !var.identity_request_certificate && var.identity_certificate_arn == null)
    error_message = "The shared host already uses the portal DNS and TLS certificate. Disable identity DNS and ACM options and omit identity_certificate_arn."
  }
}

variable "identity_image_digest" {
  description = "Digest of the reviewed optimized Keycloak image in this stack's identity ECR repository."
  type        = string
  default     = null
  validation {
    condition     = var.identity_image_digest == null ? true : can(regex("^sha256:[0-9a-f]{64}$", var.identity_image_digest))
    error_message = "Keycloak requires an immutable sha256 image digest."
  }
}

variable "identity_db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "identity_bootstrap_admin_enabled" {
  description = "Temporarily inject a separately managed bootstrap-admin secret for the first master realm. Disable after creating permanent administrators."
  type        = bool
  default     = false
}

variable "identity_admin_cidrs" {
  description = "Explicit public IPv4 operator CIDRs allowed to reach /admin. Empty denies every public administrative route."
  type        = list(string)
  default     = []
  validation {
    condition     = length(var.identity_admin_cidrs) <= 2 && alltrue([for cidr in var.identity_admin_cidrs : can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]), 0) >= 24])
    error_message = "Use at most two explicit IPv4 administrative CIDRs with /24 or narrower prefixes."
  }
}

variable "identity_manage_dns" {
  description = "Explicit opt in to create the identity alias in the supplied public hosted zone. Existing records are not overwritten."
  type        = bool
  default     = false
}

variable "identity_request_certificate" {
  description = "Explicit opt in to request an identity ACM certificate and create its DNS validation record in the supplied zone."
  type        = bool
  default     = false
}

variable "identity_dns_zone_id" {
  description = "Explicit owned public Route53 hosted zone ID; never discovered or selected by an unrelated domain."
  type        = string
  default     = null
  validation {
    condition     = !(var.identity_manage_dns || var.identity_request_certificate) || (var.identity_enabled && var.identity_dns_zone_id != null)
    error_message = "DNS or ACM management requires identity_enabled and an explicit owned public hosted zone ID."
  }
}

variable "identity_certificate_arn" {
  description = "Existing certificate covering identity_hostname. Null means the operator verified that the shared listener's certificate covers the hostname."
  type        = string
  default     = null
  validation {
    condition     = !var.identity_request_certificate || var.identity_certificate_arn == null
    error_message = "Choose an existing identity certificate or request a new one, not both."
  }
}
