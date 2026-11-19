output "identity" {
  description = "Identity resource addresses, never secret values. Presence is not evidence of a successful login."
  value = var.identity_enabled ? {
    origin                 = local.identity_origin
    base_url               = local.identity_base_url
    issuer                 = local.identity_base_url == null ? null : "${local.identity_base_url}/realms/vortexbird"
    ecr_repository_url     = aws_ecr_repository.identity[0].repository_url
    database_endpoint      = aws_db_instance.identity[0].address
    database_name          = aws_db_instance.identity[0].db_name
    database_secret_arn    = aws_secretsmanager_secret.identity["database"].arn
    bootstrap_secret_arn   = aws_secretsmanager_secret.identity["bootstrap-admin"].arn
    master_secret_arn      = aws_db_instance.identity[0].master_user_secret[0].secret_arn
    private_security_group = aws_security_group.identity[0].id
    target_group_arn       = aws_lb_target_group.identity[0].arn
    log_group              = aws_cloudwatch_log_group.identity[0].name
    service_name           = try(aws_ecs_service.identity[0].name, null)
    task_definition_arn    = try(aws_ecs_task_definition.identity[0].arn, null)
    requested_certificate  = try(aws_acm_certificate_validation.identity[0].certificate_arn, null)
  } : null
}
