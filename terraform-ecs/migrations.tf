# This task is available before ECS services are enabled, for first installation.
# Its secret must contain a dedicated schema-owner connection (VerifyFull TLS),
# never the runtime role or the RDS master account. No secret value enters state.
resource "aws_ecs_task_definition" "migration" {
  count                    = var.image_digests == null ? 0 : 1
  family                   = "${local.name}-migration"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  task_role_arn            = aws_iam_role.task["migration"].arn
  execution_role_arn       = aws_iam_role.execution["migration"].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name      = "migration"
    image     = "${aws_ecr_repository.image["backend"].repository_url}@${var.image_digests.backend}"
    essential = true
    command   = ["--migrate"]
    environment = concat([
      { name = "ASPNETCORE_ENVIRONMENT", value = "Production" },
      { name = "Authentication__DemoEnabled", value = "false" },
      { name = "Authentication__ValidIssuer", value = local.issuer },
      { name = "Database__Initialize", value = "false" },
      { name = "Seed__Enabled", value = "false" },
      { name = "Workers__Enabled", value = "false" }
    ], [for index, role in var.migration_runtime_roles : { name = "Database__RuntimeRoles__${index}", value = role }])
    secrets = [{ name = "ConnectionStrings__Database", valueFrom = "${aws_secretsmanager_secret.service["migration"].arn}:database::" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.service["migration"].name
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])
  depends_on = [aws_iam_role_policy.execution]
}
