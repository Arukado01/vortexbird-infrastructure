resource "aws_db_subnet_group" "main" {
name = local.name
subnet_ids = aws_subnet.data[*].id 
}
resource "aws_db_instance" "main" {
identifier = local.name
engine = "postgres"
engine_version = "17"
instance_class = var.db_instance_class
allocated_storage = 30
max_allocated_storage = local.production ? 500 : 100
storage_type = "gp3"
storage_encrypted = true
db_name = "vortexbird"
username = "vortexbird_admin"
manage_master_user_password = true
db_subnet_group_name = aws_db_subnet_group.main.name
vpc_security_group_ids = [aws_security_group.database.id]
publicly_accessible = false
multi_az = local.production
backup_retention_period = local.production ? 30 : 7
deletion_protection = true
skip_final_snapshot = false
final_snapshot_identifier = "${local.name}-final"
auto_minor_version_upgrade = true
enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
performance_insights_enabled = true
apply_immediately = false
}
resource "aws_elasticache_subnet_group" "main" {
name = local.name
subnet_ids = aws_subnet.data[*].id 
}
resource "aws_elasticache_replication_group" "main" {
replication_group_id = local.name
description = "VortexBird cache; inventory reservations remain authoritative in PostgreSQL"
engine = "redis"
engine_version = "7.1"
node_type = var.redis_node_type
num_cache_clusters = local.production ? 2 : 1
automatic_failover_enabled = local.production
multi_az_enabled = local.production
at_rest_encryption_enabled = true
transit_encryption_enabled = true
auth_token = var.redis_auth_token
auth_token_update_strategy = "SET"
subnet_group_name = aws_elasticache_subnet_group.main.name
security_group_ids = [aws_security_group.redis.id]
snapshot_retention_limit = local.production ? 7 : 1
}
resource "aws_secretsmanager_secret" "application" {
name = "${local.name}/application"
description = "Provision values out-of-band: non-owner application DB user, Redis, Keycloak and sandbox-only payment credentials"
recovery_window_in_days = 30
}
resource "aws_sqs_queue" "dlq" {
name = "${local.name}-events-dlq"
message_retention_seconds = 1209600
sqs_managed_sse_enabled = true
}
resource "aws_sqs_queue" "events" {
name = "${local.name}-events"
message_retention_seconds = 345600
receive_wait_time_seconds = 20
visibility_timeout_seconds = 120
sqs_managed_sse_enabled = true
redrive_policy = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dlq.arn, maxReceiveCount = 5 })
}
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
queue_url = aws_sqs_queue.dlq.id
redrive_allow_policy = jsonencode({ redrivePermission = "byQueue", sourceQueueArns = [aws_sqs_queue.events.arn] })
}
resource "aws_sqs_queue_policy" "events_tls" {
queue_url = aws_sqs_queue.events.id
policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Deny", Principal = "*", Action = "sqs:*", Resource = aws_sqs_queue.events.arn, Condition = { Bool = { "aws:SecureTransport" = "false" } } }] })
}
resource "aws_s3_bucket" "reports" {
bucket_prefix = "${local.name}-reports-" 
}
resource "aws_s3_bucket_public_access_block" "reports" {
bucket = aws_s3_bucket.reports.id
block_public_acls = true
block_public_policy = true
ignore_public_acls = true
restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "reports" {
bucket = aws_s3_bucket.reports.id
versioning_configuration {
status = "Enabled" 
}
}
resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
bucket = aws_s3_bucket.reports.id
rule {
apply_server_side_encryption_by_default {
sse_algorithm = "AES256" 
} 
}
}
resource "aws_s3_bucket_lifecycle_configuration" "reports" {
bucket = aws_s3_bucket.reports.id
rule {
id = "retention"
status = "Enabled"
filter {
prefix = "" 
}
expiration {
days = 90 
}
noncurrent_version_expiration {
noncurrent_days = 30 
}
}
}
