resource "aws_sns_topic" "alerts" {
name = "${local.name}-alerts" 
}
resource "aws_sns_topic_subscription" "email" {
count = var.alarm_email == "" ? 0 : 1
topic_arn = aws_sns_topic.alerts.arn
protocol = "email"
endpoint = var.alarm_email
}
locals {
app_alarms = {
api_5xx = { metric = "Api5xxRate", threshold = 0.01, comparison = "GreaterThanThreshold" }
api_p95 = { metric = "StockPriceLatencyP95Ms", threshold = 300, comparison = "GreaterThanThreshold" }
erp_unavailable = { metric = "ErpAvailability", threshold = 1, comparison = "LessThanThreshold" }
payment_approval = { metric = "PaymentApprovalRate", threshold = 0.85, comparison = "LessThanThreshold" }
webhooks_failed = { metric = "FailedWebhookDeliveries", threshold = 10, comparison = "GreaterThanThreshold" }
}
}
resource "aws_cloudwatch_metric_alarm" "application" {
for_each = local.app_alarms
alarm_name = "${local.name}-${each.key}"
namespace = "VortexBird"
metric_name = each.value.metric
dimensions = { Environment = var.environment }
statistic = "Average"
period = 60
evaluation_periods = 5
comparison_operator = each.value.comparison
threshold = each.value.threshold
treat_missing_data = "missing"
alarm_actions = [aws_sns_topic.alerts.arn]
alarm_description = "Requires ADOT/EMF metric publishing; review workload baseline before enabling production paging."
}
resource "aws_cloudwatch_metric_alarm" "dlq" {
alarm_name = "${local.name}-dlq-not-empty"
namespace = "AWS/SQS"
metric_name = "ApproximateNumberOfMessagesVisible"
dimensions = { QueueName = aws_sqs_queue.dlq.name }
statistic = "Maximum"
period = 60
evaluation_periods = 1
comparison_operator = "GreaterThanThreshold"
threshold = 0
treat_missing_data = "notBreaching"
alarm_actions = [aws_sns_topic.alerts.arn]
}
resource "aws_cloudwatch_metric_alarm" "db_connections" {
alarm_name = "${local.name}-db-connections"
namespace = "AWS/RDS"
metric_name = "DatabaseConnections"
dimensions = { DBInstanceIdentifier = aws_db_instance.main.id }
statistic = "Maximum"
period = 60
evaluation_periods = 5
comparison_operator = "GreaterThanThreshold"
threshold = local.production ? 200 : 60
treat_missing_data = "missing"
alarm_actions = [aws_sns_topic.alerts.arn]
}
resource "aws_wafv2_web_acl" "edge" {
name = local.name
scope = "REGIONAL"
default_action {
allow {

} 
}
visibility_config {
cloudwatch_metrics_enabled = true
metric_name = "${local.name}-waf"
sampled_requests_enabled = false
}
rule {
name = "managed-common"
priority = 1
override_action {
none {

} 
}
statement {
managed_rule_group_statement {
name = "AWSManagedRulesCommonRuleSet"
vendor_name = "AWS" 
} 
}
visibility_config {
cloudwatch_metrics_enabled = true
metric_name = "common"
sampled_requests_enabled = false 
}
}
rule {
name = "edge-ip-flood"
priority = 2
action {
block {

} 
}
statement {
rate_based_statement {
limit = 3000
aggregate_key_type = "IP" 
} 
}
visibility_config {
cloudwatch_metrics_enabled = true
metric_name = "ip-flood"
sampled_requests_enabled = false 
}
}
}
output "waf_arn" {
value = aws_wafv2_web_acl.edge.arn 
}
resource "aws_iam_role" "github_deploy" {
count = var.enable_github_role ? 1 : 0
name = "${local.name}-github-deploy"
assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
Effect = "Allow", Principal = { Federated = var.github_oidc_provider_arn }, Action = "sts:AssumeRoleWithWebIdentity",
Condition = { StringEquals = {
"token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
"token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:${var.environment}"
} }
}] })
lifecycle {
precondition {
condition = var.github_oidc_provider_arn != "" && var.github_repository != ""
error_message = "An existing OIDC provider and exact GitHub repository are required."
}
}
}
resource "aws_iam_role_policy" "github_deploy" {
count = var.enable_github_role ? 1 : 0
role = aws_iam_role.github_deploy[0].id
policy = jsonencode({ Version = "2012-10-17", Statement = [
{ Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
{ Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"], Resource = [for repository in aws_ecr_repository.images : repository.arn] },
{ Effect = "Allow", Action = ["eks:DescribeCluster"], Resource = aws_eks_cluster.main.arn }
] })
}
resource "aws_eks_access_entry" "github_deploy" {
count = var.enable_github_role ? 1 : 0
cluster_name = aws_eks_cluster.main.name
principal_arn = aws_iam_role.github_deploy[0].arn
kubernetes_groups = ["vortexbird-deployers"]
type = "STANDARD"
}
