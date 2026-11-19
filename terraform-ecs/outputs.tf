output "alb_dns_name" {
  value = aws_lb.edge.dns_name
}

output "ecr_repositories" {
  value = { for role, repository in aws_ecr_repository.image : role => repository.repository_url }
}

output "service_secret_arns" {
  value = { for role, secret in aws_secretsmanager_secret.service : role => secret.arn }
}

output "postgres_endpoint" {
  value = aws_db_instance.main.endpoint
}

output "redis_endpoint" {
  value = try(aws_elasticache_replication_group.main[0].primary_endpoint_address, null)
}

output "queue_urls" {
  value = { events = aws_sqs_queue.events.url, dlq = aws_sqs_queue.dlq.url }
}

output "release_contract" {
  description = "Non-secret input for scripts/release-ecs.cjs. Export after an approved apply; never invent resource identifiers."
  value = {
    accountId       = data.aws_caller_identity.current.account_id
    region          = var.region
    environment     = var.environment
    clusterArn      = aws_ecs_cluster.main.arn
    repositories    = { for role, repository in aws_ecr_repository.image : role => repository.repository_url }
    taskDefinitions = { for role, definition in aws_ecs_task_definition.service : role => definition.arn }
    targetGroups    = { for role, target in aws_lb_target_group.service : role => target.arn }
    portalOrigin    = var.portal_origin
    oidcIssuer      = local.issuer
    migration = {
      taskDefinitionArn = try(aws_ecs_task_definition.migration[0].arn, null)
      subnets           = local.app_subnets
      securityGroups    = [aws_security_group.tier["migration"].id]
    }
  }
}
