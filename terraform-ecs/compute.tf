resource "aws_ecr_repository" "image" {
  for_each             = toset(["frontend", "backend"])
  name                 = "${local.name}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_cloudwatch_log_group" "service" {
  for_each          = local.task_containers
  name              = "/ecs/${local.name}/${each.key}"
  retention_in_days = local.production ? 90 : 30
}

resource "aws_ecs_cluster" "main" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_lb" "edge" {
  name                       = local.name
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = local.public_subnets
  security_groups            = [aws_security_group.tier["alb"].id]
  drop_invalid_header_fields = true
  desync_mitigation_mode     = "strictest"
  enable_deletion_protection = local.production
  depends_on                 = [aws_route_table_association.tiers]
}

resource "aws_lb_target_group" "service" {
  for_each    = toset(["frontend", "api"])
  name        = "vb-ecs-${var.environment}-${each.key}"
  vpc_id      = aws_vpc.main.id
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  health_check {
    path    = each.key == "frontend" ? "/health" : "/health/ready"
    matcher = "200"
  }
}

resource "aws_lb_listener" "http" {
  count             = var.certificate_arn == null ? 0 : 1
  load_balancer_arn = aws_lb.edge.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = var.certificate_arn == null ? 0 : 1
  load_balancer_arn = aws_lb.edge.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service["frontend"].arn
  }
}

resource "aws_lb_listener_rule" "api" {
  count        = var.certificate_arn == null ? 0 : 1
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service["api"].arn
  }
  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}

locals {
  issuer = var.keycloak_url == null ? "" : "${var.keycloak_url}/realms/vortexbird"
  shared_backend_environment = {
    ASPNETCORE_ENVIRONMENT              = "Production"
    Authentication__DemoEnabled         = "false"
    Authentication__Authority           = local.issuer
    Authentication__ValidIssuer         = local.issuer
    Database__Initialize                = "false"
    Seed__Enabled                       = "false"
    Payments__Provider                  = "Simulator"
    Messaging__Provider                 = "sqs"
    Messaging__Region                   = var.region
    Messaging__QueueUrl                 = aws_sqs_queue.events.url
    Messaging__VisibilityTimeoutSeconds = tostring(aws_sqs_queue.events.visibility_timeout_seconds)
    Messaging__MaxAttempts              = "5"
  }
  frontend_environment = {
    VITE_API_BASE_URL = "/api/v1"
    VITE_KEYCLOAK_URL = var.keycloak_url == null ? "" : var.keycloak_url
    VITE_DEMO_AUTH    = "false"
    API_PROXY_ENABLED = "false"
  }
}

resource "aws_ecs_task_definition" "service" {
  for_each                 = local.services
  family                   = "${local.name}-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = each.key == "frontend" ? "256" : "512"
  memory                   = each.key == "frontend" ? "512" : "1024"
  task_role_arn            = aws_iam_role.task[each.key].arn
  execution_role_arn       = aws_iam_role.execution[each.key].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([merge({
    name         = each.key
    image        = "${aws_ecr_repository.image[each.key == "frontend" ? "frontend" : "backend"].repository_url}@${try(each.key == "frontend" ? var.image_digests.frontend : var.image_digests.backend, "")}"
    essential    = true
    portMappings = each.key == "worker" ? [] : [{ containerPort = 8080, protocol = "tcp" }]
    environment = [for name, value in(each.key == "frontend" ? tomap(local.frontend_environment) : merge(local.shared_backend_environment, {
      Workers__Enabled        = each.key == "worker" ? "true" : "false"
      Cors__AllowedOrigins__0 = var.portal_origin == null ? "" : var.portal_origin
    })) : { name = name, value = value }]
    secrets = each.key == "frontend" ? [] : concat([
      { name = "ConnectionStrings__Database", valueFrom = "${aws_secretsmanager_secret.service[each.key].arn}:database::" }
      ], var.redis_user_group_id == null ? [] : [
      { name = "ConnectionStrings__Redis", valueFrom = "${aws_secretsmanager_secret.service[each.key].arn}:redis::" }
    ])
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.service[each.key].name
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
    }, each.key != "worker" ? {} : {
    healthCheck = {
      command     = ["CMD", "dotnet", "VortexBird.API.dll", "--readiness-probe"]
      interval    = 30
      timeout     = 8
      retries     = 3
      startPeriod = 45
    }
  })])

  lifecycle {
    precondition {
      condition     = var.certificate_arn != null && var.portal_origin != null && var.keycloak_url != null && var.image_digests != null
      error_message = "Services require an ACM certificate, portal origin, Keycloak URL and both ECR image digests."
    }
  }
  depends_on = [aws_iam_role_policy.execution, aws_iam_role_policy.worker_sqs]
}

resource "aws_ecs_service" "service" {
  for_each                          = local.services
  name                              = each.key
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.service[each.key].arn
  launch_type                       = "FARGATE"
  platform_version                  = "1.4.0"
  desired_count                     = local.production ? 2 : 1
  health_check_grace_period_seconds = each.key == "worker" ? null : 60

  network_configuration {
    subnets          = local.app_subnets
    security_groups  = [aws_security_group.tier[each.key].id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = each.key == "worker" ? [] : [each.key]
    content {
      target_group_arn = aws_lb_target_group.service[load_balancer.value].arn
      container_name   = each.key
      container_port   = 8080
    }
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    # CI owns the deployed revision; Terraform still owns the task templates.
    ignore_changes = [desired_count, task_definition]
  }
  depends_on = [aws_lb_listener_rule.api, aws_route_table_association.tiers, aws_vpc_security_group_ingress_rule.private_flows, aws_vpc_security_group_egress_rule.private_flows, aws_vpc_security_group_egress_rule.https]
}

resource "aws_appautoscaling_target" "service" {
  for_each           = local.services
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.service[each.key].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = local.production ? 2 : 1
  max_capacity       = local.production ? 10 : 3
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each           = aws_appautoscaling_target.service
  name               = "${local.name}-${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = each.value.resource_id
  scalable_dimension = each.value.scalable_dimension
  service_namespace  = each.value.service_namespace
  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 180
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
