# Optional identity tier. It never reads secret values into Terraform state.
locals {
  identity_create       = var.identity_enabled ? 1 : 0
  identity_run          = var.identity_enabled && var.identity_deploy_service ? 1 : 0
  identity_dns          = var.identity_enabled && (var.identity_manage_dns || var.identity_request_certificate)
  identity_origin       = var.identity_hostname == null ? null : "https://${var.identity_hostname}"
  identity_prefix       = var.identity_shared_host ? "/auth" : ""
  identity_base_url     = local.identity_origin == null ? null : "${local.identity_origin}${local.identity_prefix}"
  identity_admin_paths  = ["${local.identity_prefix}/admin", "${local.identity_prefix}/admin/*"]
  identity_secret_names = var.identity_enabled ? toset(["database", "bootstrap-admin"]) : toset([])
  identity_injected_secrets = var.identity_enabled ? concat(
    [aws_secretsmanager_secret.identity["database"].arn],
    var.identity_bootstrap_admin_enabled ? [aws_secretsmanager_secret.identity["bootstrap-admin"].arn] : []
  ) : []
}

resource "aws_ecr_repository" "identity" {
  count                = local.identity_create
  name                 = "${local.name}-identity"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

resource "aws_cloudwatch_log_group" "identity" {
  count             = local.identity_create
  name              = "/ecs/${local.name}/identity"
  retention_in_days = local.production ? 90 : 30
}

resource "aws_security_group" "identity" {
  count       = local.identity_create
  name_prefix = "${local.name}-identity-"
  description = "Private Keycloak: ALB traffic and management probes only"
  vpc_id      = aws_vpc.main.id
  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "identity_database" {
  count       = local.identity_create
  name_prefix = "${local.name}-identity-db-"
  description = "Dedicated identity database; no application tier or public access"
  vpc_id      = aws_vpc.main.id
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "identity_alb" {
  for_each                     = var.identity_enabled ? toset(["8080", "9000"]) : toset([])
  security_group_id            = aws_security_group.identity[0].id
  referenced_security_group_id = aws_security_group.tier["alb"].id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

resource "aws_vpc_security_group_egress_rule" "alb_identity" {
  for_each                     = var.identity_enabled ? toset(["8080", "9000"]) : toset([])
  security_group_id            = aws_security_group.tier["alb"].id
  referenced_security_group_id = aws_security_group.identity[0].id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

resource "aws_vpc_security_group_ingress_rule" "identity_database" {
  count                        = local.identity_create
  security_group_id            = aws_security_group.identity_database[0].id
  referenced_security_group_id = aws_security_group.identity[0].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "identity_database" {
  count                        = local.identity_create
  security_group_id            = aws_security_group.identity[0].id
  referenced_security_group_id = aws_security_group.identity_database[0].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "identity_https" {
  count             = local.identity_create
  security_group_id = aws_security_group.identity[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# Keycloak jdbc-ping discovery uses its own DB; transport and failure detection stay within the identity SG.
resource "aws_vpc_security_group_ingress_rule" "identity_cluster" {
  for_each                     = var.identity_enabled ? toset(["7800", "57800"]) : toset([])
  security_group_id            = aws_security_group.identity[0].id
  referenced_security_group_id = aws_security_group.identity[0].id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

resource "aws_vpc_security_group_egress_rule" "identity_cluster" {
  for_each                     = var.identity_enabled ? toset(["7800", "57800"]) : toset([])
  security_group_id            = aws_security_group.identity[0].id
  referenced_security_group_id = aws_security_group.identity[0].id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

resource "aws_db_subnet_group" "identity" {
  count      = local.identity_create
  name       = "${local.name}-identity"
  subnet_ids = local.data_subnets
}

resource "aws_db_instance" "identity" {
  count                           = local.identity_create
  identifier                      = "${local.name}-identity"
  engine                          = "postgres"
  engine_version                  = "17"
  instance_class                  = var.identity_db_instance_class
  allocated_storage               = 20
  max_allocated_storage           = local.production ? 200 : 50
  storage_type                    = "gp3"
  storage_encrypted               = true
  db_name                         = "keycloak"
  username                        = "identity_admin"
  manage_master_user_password     = true
  db_subnet_group_name            = aws_db_subnet_group.identity[0].name
  vpc_security_group_ids          = [aws_security_group.identity_database[0].id]
  publicly_accessible             = false
  multi_az                        = local.production
  backup_retention_period         = local.production ? 30 : 7
  deletion_protection             = true
  skip_final_snapshot             = false
  final_snapshot_identifier       = "${local.name}-identity-final"
  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = ["postgresql"]
}

resource "aws_secretsmanager_secret" "identity" {
  for_each                = local.identity_secret_names
  name                    = "${local.name}/identity/${each.key}"
  description             = "Populate out of band with username/password JSON; never inject the RDS master credentials into Keycloak"
  kms_key_id              = var.secrets_kms_key_arn
  recovery_window_in_days = 30
}

resource "aws_iam_role" "identity_task" {
  count              = local.identity_create
  name               = "${local.name}-identity-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks.json
}

resource "aws_iam_role" "identity_execution" {
  count              = local.identity_create
  name               = "${local.name}-identity-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks.json
}

data "aws_iam_policy_document" "identity_execution" {
  count = local.identity_create
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.identity[0].arn]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.identity[0].arn}:log-stream:*"]
  }
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.identity_injected_secrets
  }
  dynamic "statement" {
    for_each = var.secrets_kms_key_arn == null ? [] : [var.secrets_kms_key_arn]
    content {
      actions   = ["kms:Decrypt"]
      resources = [statement.value]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.region}.${data.aws_partition.current.dns_suffix}"]
      }
      condition {
        test     = "StringEquals"
        variable = "kms:EncryptionContext:SecretARN"
        values   = local.identity_injected_secrets
      }
    }
  }
}

resource "aws_iam_role_policy" "identity_execution" {
  count  = local.identity_create
  name   = "identity-image-logs-and-scoped-injection"
  role   = aws_iam_role.identity_execution[0].id
  policy = data.aws_iam_policy_document.identity_execution[0].json
}

data "aws_route53_zone" "identity" {
  count   = local.identity_dns ? 1 : 0
  zone_id = var.identity_dns_zone_id
  lifecycle {
    postcondition {
      condition     = !self.private_zone && endswith(var.identity_hostname, ".${trimsuffix(self.name, ".")}")
      error_message = "Identity DNS must be a subdomain of the explicitly supplied public hosted zone."
    }
  }
}

resource "aws_acm_certificate" "identity" {
  count             = var.identity_enabled && var.identity_request_certificate ? 1 : 0
  domain_name       = var.identity_hostname
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "identity_certificate" {
  for_each = var.identity_enabled && var.identity_request_certificate ? {
    for option in aws_acm_certificate.identity[0].domain_validation_options : option.domain_name => option
  } : {}
  zone_id         = data.aws_route53_zone.identity[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = false
}

resource "aws_acm_certificate_validation" "identity" {
  count                   = var.identity_enabled && var.identity_request_certificate ? 1 : 0
  certificate_arn         = aws_acm_certificate.identity[0].arn
  validation_record_fqdns = [for record in aws_route53_record.identity_certificate : record.fqdn]
}

resource "aws_lb_listener_certificate" "identity" {
  count           = local.identity_run == 1 && (var.identity_request_certificate || (var.identity_certificate_arn != null && var.identity_certificate_arn != var.certificate_arn)) ? 1 : 0
  listener_arn    = aws_lb_listener.https[0].arn
  certificate_arn = var.identity_request_certificate ? aws_acm_certificate_validation.identity[0].certificate_arn : var.identity_certificate_arn
}

resource "aws_route53_record" "identity" {
  count           = var.identity_enabled && var.identity_manage_dns ? 1 : 0
  zone_id         = data.aws_route53_zone.identity[0].zone_id
  name            = var.identity_hostname
  type            = "A"
  allow_overwrite = false
  alias {
    name                   = aws_lb.edge.dns_name
    zone_id                = aws_lb.edge.zone_id
    evaluate_target_health = true
  }
}

resource "aws_lb_target_group" "identity" {
  count                = local.identity_create
  name                 = "vb-id-${var.environment}"
  vpc_id               = aws_vpc.main.id
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  deregistration_delay = 30
  health_check {
    path                = "/health/ready"
    port                = "9000"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  stickiness {
    type            = "lb_cookie"
    enabled         = true
    cookie_duration = 300
  }
}

# Rules 1 and 2 restrict the administrative console; rule 5 precedes the application's /api/* rule 10.
resource "aws_lb_listener_rule" "identity_admin_allow" {
  count        = local.identity_run == 1 && length(var.identity_admin_cidrs) > 0 ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 1
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.identity[0].arn
  }
  condition {
    host_header {
      values = [var.identity_hostname]
    }
  }
  condition {
    path_pattern {
      values = local.identity_admin_paths
    }
  }
  condition {
    source_ip {
      values = var.identity_admin_cidrs
    }
  }
  dynamic "transform" {
    for_each = var.identity_shared_host ? [1] : []
    content {
      type = "url-rewrite"
      url_rewrite_config {
        rewrite {
          regex   = "^/auth(/.*)$"
          replace = "$1"
        }
      }
    }
  }
}

resource "aws_lb_listener_rule" "identity_admin_deny" {
  count        = local.identity_run
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 2
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
      message_body = "Administrative access is restricted."
    }
  }
  condition {
    host_header {
      values = [var.identity_hostname]
    }
  }
  condition {
    path_pattern {
      values = local.identity_admin_paths
    }
  }
}

resource "aws_lb_listener_rule" "identity" {
  count        = local.identity_run
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 5
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.identity[0].arn
  }
  condition {
    host_header {
      values = [var.identity_hostname]
    }
  }
  condition {
    path_pattern {
      values = [for path in ["/realms/*", "/resources/*", "/.well-known/*"] : "${local.identity_prefix}${path}"]
    }
  }
  dynamic "transform" {
    for_each = var.identity_shared_host ? [1] : []
    content {
      type = "url-rewrite"
      url_rewrite_config {
        rewrite {
          regex   = "^/auth(/.*)$"
          replace = "$1"
        }
      }
    }
  }
}

# RFC 8414 inserts .well-known before the issuer path. Keep other portal metadata paths untouched.
resource "aws_lb_listener_rule" "identity_discovery" {
  count        = local.identity_run == 1 && var.identity_shared_host ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 4
  condition {
    host_header {
      values = [var.identity_hostname]
    }
  }
  condition {
    path_pattern {
      values = ["/.well-known/oauth-authorization-server/auth/realms/vortexbird", "/.well-known/openid-configuration/auth/realms/vortexbird"]
    }
  }
  transform {
    type = "url-rewrite"
    url_rewrite_config {
      rewrite {
        regex   = "^(/\\.well-known/[^/]+)/auth(/realms/vortexbird.*)$"
        replace = "$1$2"
      }
    }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.identity[0].arn
  }
}

resource "aws_lb_listener_rule" "identity_default_deny" {
  count        = local.identity_run
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 6
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
      message_body = "Identity route is not public."
    }
  }
  condition {
    host_header {
      values = [var.identity_hostname]
    }
  }
  dynamic "condition" {
    for_each = var.identity_shared_host ? [1] : []
    content {
      path_pattern {
        values = ["/auth", "/auth/*"]
      }
    }
  }
}

resource "aws_ecs_task_definition" "identity" {
  count                    = local.identity_run
  family                   = "${local.name}-identity"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "2048"
  task_role_arn            = aws_iam_role.identity_task[0].arn
  execution_role_arn       = aws_iam_role.identity_execution[0].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name         = "identity"
    image        = "${aws_ecr_repository.identity[0].repository_url}@${coalesce(var.identity_image_digest, "missing-reviewed-digest")}"
    essential    = true
    command      = ["start", "--optimized", "--import-realm"]
    portMappings = [{ containerPort = 8080, protocol = "tcp" }, { containerPort = 9000, protocol = "tcp" }]
    environment = [for name, value in {
      KC_DB                      = "postgres"
      KC_DB_URL                  = "jdbc:postgresql://${aws_db_instance.identity[0].address}:5432/keycloak?sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca-bundle.pem"
      KC_DB_SCHEMA               = "keycloak"
      KC_HOSTNAME                = local.identity_base_url
      KC_HOSTNAME_STRICT         = "true"
      KC_HTTP_ENABLED            = "true"
      KC_HTTP_MANAGEMENT_PORT    = "9000"
      KC_HTTP_MANAGEMENT_SCHEME  = "http"
      KC_PROXY_HEADERS           = "xforwarded"
      KC_PROXY_TRUSTED_ADDRESSES = join(",", [aws_subnet.tiers["public-a"].cidr_block, aws_subnet.tiers["public-b"].cidr_block])
      KC_HEALTH_ENABLED          = "true"
      KC_METRICS_ENABLED         = "true"
      KC_CACHE                   = "ispn"
      KC_CACHE_STACK             = "jdbc-ping"
      KC_LOG                     = "console"
      KC_LOG_CONSOLE_OUTPUT      = "json"
      KC_DB_POOL_INITIAL_SIZE    = "5"
      KC_DB_POOL_MIN_SIZE        = "5"
      KC_DB_POOL_MAX_SIZE        = "20"
      VORTEXBIRD_PORTAL_ORIGIN   = var.portal_origin == null ? "" : var.portal_origin
    } : { name = name, value = value }]
    secrets = concat([
      { name = "KC_DB_USERNAME", valueFrom = "${aws_secretsmanager_secret.identity["database"].arn}:username::" },
      { name = "KC_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.identity["database"].arn}:password::" }
      ], var.identity_bootstrap_admin_enabled ? [
      { name = "KC_BOOTSTRAP_ADMIN_USERNAME", valueFrom = "${aws_secretsmanager_secret.identity["bootstrap-admin"].arn}:username::" },
      { name = "KC_BOOTSTRAP_ADMIN_PASSWORD", valueFrom = "${aws_secretsmanager_secret.identity["bootstrap-admin"].arn}:password::" }
    ] : [])
    healthCheck = {
      command     = ["CMD-SHELL", "bash -ec 'exec 3<>/dev/tcp/127.0.0.1/9000; printf \"HEAD /health/ready HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n\" >&3; read -r status <&3; [[ \"$status\" == *\" 200 \"* ]]'"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 120
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.identity[0].name
        awslogs-region        = var.region
        awslogs-stream-prefix = "identity"
      }
    }
  }])
  lifecycle {
    precondition {
      condition = (var.certificate_arn != null && var.identity_image_digest != null && var.keycloak_url == local.identity_base_url && var.portal_origin != null &&
      (var.identity_shared_host ? var.portal_origin == local.identity_origin : var.portal_origin != local.identity_origin))
      error_message = "Identity service requires a listener certificate, an image digest and the HTTPS Keycloak URL matching the selected host mode."
    }
  }
  depends_on = [aws_iam_role_policy.identity_execution]
}

resource "aws_ecs_service" "identity" {
  count                             = local.identity_run
  name                              = "identity"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.identity[0].arn
  launch_type                       = "FARGATE"
  platform_version                  = "1.4.0"
  desired_count                     = local.production ? 2 : 1
  health_check_grace_period_seconds = 240
  network_configuration {
    subnets          = local.app_subnets
    security_groups  = [aws_security_group.identity[0].id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.identity[0].arn
    container_name   = "identity"
    container_port   = 8080
  }
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  depends_on = [aws_lb_listener_rule.identity, aws_lb_listener_rule.identity_admin_deny, aws_lb_listener_rule.identity_default_deny, aws_lb_listener_certificate.identity, aws_route_table_association.tiers, aws_vpc_security_group_ingress_rule.identity_alb, aws_vpc_security_group_egress_rule.alb_identity, aws_vpc_security_group_ingress_rule.identity_database, aws_vpc_security_group_egress_rule.identity_database, aws_vpc_security_group_egress_rule.identity_https]
}
