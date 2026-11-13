output "cluster_name" {
value = aws_eks_cluster.main.name 
}
output "ecr_repositories" {
value = { for key, value in aws_ecr_repository.images : key => value.repository_url } 
}
output "backend_role_arn" {
value = aws_iam_role.backend.arn 
}
output "application_secret_arn" {
value = aws_secretsmanager_secret.application.arn 
}
output "database_endpoint" {
value = aws_db_instance.main.address 
}
output "database_master_secret_arn" {
value = aws_db_instance.main.master_user_secret[0].secret_arn
sensitive = true 
}
output "redis_endpoint" {
value = aws_elasticache_replication_group.main.primary_endpoint_address 
}
output "queue_url" {
value = aws_sqs_queue.events.url 
}
output "dlq_url" {
value = aws_sqs_queue.dlq.url 
}
output "public_subnets" {
value = aws_subnet.public[*].id 
}
