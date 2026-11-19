mock_provider "aws" {
  override_during = plan

  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-2a", "us-east-2b"] }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = {
      arn = "arn:aws:sqs:us-east-2:123456789012:fixture"
      url = "https://sqs.us-east-2.amazonaws.com/123456789012/fixture"
    }
  }
  mock_resource "aws_ecr_repository" {
    defaults = { repository_url = "123456789012.dkr.ecr.us-east-2.amazonaws.com/fixture" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:fixture-012345" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:us-east-2:123456789012:secret:fixture-012345" }]
    }
  }
}

variables {
  environment = "staging"
  vpc_cidr    = "10.75.0.0/16"
}

run "bootstrap_before_dependencies" {
  command = plan

  assert {
    condition     = length(aws_ecs_service.service) == 0 && length(aws_lb_listener.https) == 0
    error_message = "The bootstrap phase must leave services and HTTPS inactive."
  }
  assert {
    condition     = !aws_db_instance.main.publicly_accessible && aws_db_instance.main.storage_encrypted
    error_message = "PostgreSQL must remain private and encrypted."
  }
  assert {
    condition     = jsondecode(aws_sqs_queue.events.redrive_policy).maxReceiveCount == 5
    error_message = "SQS must redrive after five receives."
  }
}

run "identity_foundation_without_hostname" {
  command = plan
  variables {
    identity_enabled = true
  }
  assert {
    condition = (length(aws_db_instance.identity) == 1 && length(aws_ecr_repository.identity) == 1 &&
      length(aws_ecs_service.identity) == 0 && length(aws_route53_record.identity) == 0 &&
      length(aws_acm_certificate.identity) == 0 &&
    output.identity.origin == null && output.identity.issuer == null)
    error_message = "The identity foundation must plan its database and repository without a public endpoint."
  }
}

run "identity_service_requires_hostname" {
  command = plan
  variables {
    identity_enabled        = true
    identity_deploy_service = true
  }
  expect_failures = [var.identity_hostname]
}

run "identity_dns_requires_hostname" {
  command = plan
  variables {
    identity_enabled     = true
    identity_manage_dns  = true
    identity_dns_zone_id = "Z1234567890"
  }
  expect_failures = [var.identity_hostname]
}

run "identity_acm_request_requires_hostname" {
  command = plan
  variables {
    identity_enabled             = true
    identity_request_certificate = true
    identity_dns_zone_id         = "Z1234567890"
  }
  expect_failures = [var.identity_hostname]
}

run "identity_existing_certificate_requires_hostname" {
  command = plan
  variables {
    identity_enabled         = true
    identity_certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  }
  expect_failures = [var.identity_hostname]
}

run "release_services" {
  command = plan
  variables {
    deploy_services     = true
    certificate_arn     = "arn:aws:acm:us-east-2:123456789012:certificate/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    portal_origin       = "https://portal.example.com"
    keycloak_url        = "https://identity.example.com"
    redis_user_group_id = "fixture"
    image_digests = {
      frontend = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      backend  = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  }
  assert {
    condition = toset(keys(aws_ecs_service.service)) == toset(["api", "frontend", "worker"]) && alltrue([
      for service in aws_ecs_service.service : service.launch_type == "FARGATE" && !service.network_configuration[0].assign_public_ip
    ])
    error_message = "The release must use private Fargate tasks."
  }
  assert {
    condition = length(aws_ecs_service.service["worker"].load_balancer) == 0 && alltrue([
      for key in ["frontend", "api"] : length(aws_ecs_service.service[key].load_balancer) == 1
    ])
    error_message = "The ALB must expose only the frontend and API."
  }
  assert {
    condition     = length(aws_iam_role.execution) == 4 && length(aws_iam_role.task) == 4 && aws_iam_role_policy.worker_sqs.role == aws_iam_role.task["worker"].name
    error_message = "SQS permissions must be assigned to the worker task role."
  }
  assert {
    condition = (length(aws_ecs_task_definition.migration) == 1 &&
      jsondecode(aws_ecs_task_definition.migration[0].container_definitions)[0].command == ["--migrate"] &&
    aws_ecs_task_definition.migration[0].execution_role_arn == aws_iam_role.execution["migration"].arn)
    error_message = "Migration must run separately under its own execution identity."
  }
  assert {
    condition     = length(aws_elasticache_replication_group.main) == 1 && aws_elasticache_replication_group.main[0].transit_encryption_enabled
    error_message = "The optional Redis configuration must use TLS."
  }
}

run "identity_shared_host" {
  command = plan
  variables {
    identity_enabled        = true
    identity_deploy_service = true
    identity_shared_host    = true
    identity_admin_cidrs    = ["192.0.2.14/32"]
    certificate_arn         = "arn:aws:acm:us-east-2:123456789012:certificate/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    identity_image_digest   = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    portal_origin           = "https://portal.example.com"
    identity_hostname       = "portal.example.com"
    keycloak_url            = "https://portal.example.com/auth"
  }
  assert {
    condition = (
      output.identity.origin == var.portal_origin && output.identity.base_url == var.keycloak_url &&
      output.identity.issuer == "${var.keycloak_url}/realms/vortexbird" && output.release_contract.oidcIssuer == output.identity.issuer &&
      one([for entry in jsondecode(aws_ecs_task_definition.identity[0].container_definitions)[0].environment : entry.value if entry.name == "KC_HOSTNAME"]) == var.keycloak_url
    )
    error_message = "Keycloak, discovery and application tokens must use the same public /auth base URL."
  }
  assert {
    condition = (
      length(aws_route53_record.identity) == 0 && length(aws_acm_certificate.identity) == 0 && length(aws_lb_listener_certificate.identity) == 0 &&
      one(aws_lb_target_group.identity[0].health_check).port == "9000" && one(aws_lb_target_group.identity[0].health_check).path == "/health/ready"
    )
    error_message = "The shared host needs one certificate and DNS record. The ALB must continue checking the internal management endpoint."
  }
  assert {
    condition = alltrue([for rule in [aws_lb_listener_rule.identity_admin_allow[0], aws_lb_listener_rule.identity[0]] :
      replace("/auth/realms/vortexbird/login-actions/authenticate?code=abc&state=123", "/${one(one(one(rule.transform).url_rewrite_config).rewrite).regex}/", one(one(one(rule.transform).url_rewrite_config).rewrite).replace) ==
      "/realms/vortexbird/login-actions/authenticate?code=abc&state=123"
    ])
    error_message = "Remove only /auth on forwarded identity requests and preserve the full query."
  }
  assert {
    condition = (
      one([for c in aws_lb_listener_rule.identity_admin_allow[0].condition : one(c.source_ip).values if length(c.source_ip) > 0]) == toset(var.identity_admin_cidrs) &&
      alltrue([for rule in [aws_lb_listener_rule.identity_admin_allow[0], aws_lb_listener_rule.identity_admin_deny[0]] :
      one([for c in rule.condition : one(c.path_pattern).values if length(c.path_pattern) > 0]) == toset(["/auth/admin", "/auth/admin/*"])]) &&
      one([for c in aws_lb_listener_rule.identity_default_deny[0].condition : one(c.path_pattern).values if length(c.path_pattern) > 0]) == toset(["/auth", "/auth/*"]) &&
      one([for c in aws_lb_listener_rule.identity[0].condition : one(c.path_pattern).values if length(c.path_pattern) > 0]) == toset(["/auth/realms/*", "/auth/resources/*", "/auth/.well-known/*"])
    )
    error_message = "Apply the admin allowlist and the identity deny rule only to the Keycloak mount, keeping portal and API paths available."
  }
  assert {
    condition = (
      replace("/.well-known/oauth-authorization-server/auth/realms/vortexbird?check=1", "/${one(one(one(aws_lb_listener_rule.identity_discovery[0].transform).url_rewrite_config).rewrite).regex}/", one(one(one(aws_lb_listener_rule.identity_discovery[0].transform).url_rewrite_config).rewrite).replace) ==
      "/.well-known/oauth-authorization-server/realms/vortexbird?check=1"
    )
    error_message = "RFC 8414 discovery must reach the internal realm with query parameters intact."
  }
}

run "identity_dedicated_host" {
  command = plan
  variables {
    identity_enabled        = true
    identity_deploy_service = true
    certificate_arn         = "arn:aws:acm:us-east-2:123456789012:certificate/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    identity_image_digest   = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    portal_origin           = "https://portal.example.com"
    identity_hostname       = "id.example.com"
    keycloak_url            = "https://id.example.com"
  }
  assert {
    condition = (
      output.identity.origin == var.keycloak_url && output.identity.base_url == var.keycloak_url &&
      output.identity.issuer == "${var.keycloak_url}/realms/vortexbird" && length(aws_lb_listener_rule.identity[0].transform) == 0 &&
      length(aws_lb_listener_rule.identity_admin_allow) == 0 && length(aws_lb_listener_rule.identity_default_deny[0].condition) == 1 &&
      length(aws_lb_listener_rule.identity_discovery) == 0 &&
      one([for c in aws_lb_listener_rule.identity[0].condition : one(c.path_pattern).values if length(c.path_pattern) > 0]) == toset(["/realms/*", "/resources/*", "/.well-known/*"])
    )
    error_message = "Dedicated identity hosts must keep the original routes and the host-wide deny rule."
  }
}

run "shared_host_requires_matching_identity_url" {
  command = plan
  variables {
    identity_enabled     = true
    identity_shared_host = true
    portal_origin        = "https://portal.example.com"
    identity_hostname    = "portal.example.com"
    keycloak_url         = "https://other.example.com/auth"
  }
  expect_failures = [var.identity_shared_host]
}

run "shared_host_rejects_duplicate_certificate" {
  command = plan
  variables {
    identity_enabled         = true
    identity_shared_host     = true
    identity_certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/cccccccc-bbbb-cccc-dddd-eeeeeeeeeeee"
    portal_origin            = "https://portal.example.com"
    identity_hostname        = "portal.example.com"
    keycloak_url             = "https://portal.example.com/auth"
  }
  expect_failures = [var.identity_shared_host]
}
