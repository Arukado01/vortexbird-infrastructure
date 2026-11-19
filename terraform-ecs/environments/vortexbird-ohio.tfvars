# HTTPS settings for the VortexBird pilot. Load after development.tfvars when planning the listener.
portal_origin        = "https://vortexbird.pgecolombia.com"
keycloak_url         = "https://vortexbird.pgecolombia.com/auth"
identity_enabled     = true
identity_shared_host = true
identity_hostname    = "vortexbird.pgecolombia.com"
certificate_arn      = "arn:aws:acm:us-east-2:946876341107:certificate/8c536a01-a333-4a8f-a2e6-0423b637488f"
