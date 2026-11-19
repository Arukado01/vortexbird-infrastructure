resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = local.data_subnets
}

resource "aws_db_instance" "main" {
  identifier                      = local.name
  engine                          = "postgres"
  engine_version                  = "17"
  instance_class                  = var.db_instance_class
  allocated_storage               = 30
  max_allocated_storage           = local.production ? 500 : 100
  storage_type                    = "gp3"
  storage_encrypted               = true
  db_name                         = "vortexbird"
  username                        = "vortexbird_admin"
  manage_master_user_password     = true
  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.tier["postgres"].id]
  publicly_accessible             = false
  multi_az                        = local.production
  backup_retention_period         = local.production ? 30 : 7
  deletion_protection             = true
  skip_final_snapshot             = false
  final_snapshot_identifier       = "${local.name}-final"
  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = ["postgresql"]
}

resource "aws_elasticache_subnet_group" "main" {
  count      = var.redis_user_group_id == null ? 0 : 1
  name       = local.name
  subnet_ids = local.data_subnets
}

resource "aws_elasticache_replication_group" "main" {
  count                      = var.redis_user_group_id == null ? 0 : 1
  replication_group_id       = local.name
  description                = "TLS Redis cache for VortexBird"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = var.redis_node_type
  num_cache_clusters         = local.production ? 2 : 1
  automatic_failover_enabled = local.production
  multi_az_enabled           = local.production
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  user_group_ids             = [var.redis_user_group_id]
  subnet_group_name          = aws_elasticache_subnet_group.main[0].name
  security_group_ids         = [aws_security_group.tier["redis"].id]
  snapshot_retention_limit   = local.production ? 7 : 1
}

resource "aws_secretsmanager_secret" "service" {
  for_each                = toset(["api", "worker", "migration"])
  name                    = "${local.name}/${each.key}"
  description             = each.key == "migration" ? "Dedicated PostgreSQL schema-owner connection; never runtime or RDS master credentials" : "Populate out of band with non-owner PostgreSQL connection and optional Redis URL"
  kms_key_id              = var.secrets_kms_key_arn
  recovery_window_in_days = 30
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name}-events-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "events" {
  name                       = "${local.name}-events"
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  visibility_timeout_seconds = 120
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.events.arn]
  })
}

resource "aws_sqs_queue_policy" "tls" {
  for_each  = toset(["events", "dlq"])
  queue_url = each.key == "events" ? aws_sqs_queue.events.id : aws_sqs_queue.dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Deny"
      Principal = "*"
      Action    = "sqs:*"
      Resource  = each.key == "events" ? aws_sqs_queue.events.arn : aws_sqs_queue.dlq.arn
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}
