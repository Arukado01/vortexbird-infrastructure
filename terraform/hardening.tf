resource "aws_kms_key" "eks" {
description = "${local.name} Kubernetes secret encryption"
enable_key_rotation = true
deletion_window_in_days = 30
}
resource "aws_kms_alias" "eks" {
name = "alias/${local.name}-eks"
target_key_id = aws_kms_key.eks.key_id
}
resource "aws_launch_template" "nodes" {
name_prefix = "${local.name}-nodes-"
metadata_options {
http_endpoint = "enabled"
http_tokens = "required"
http_put_response_hop_limit = 1
}
block_device_mappings {
device_name = "/dev/xvda"
ebs {
volume_size = 30
volume_type = "gp3"
encrypted = true
delete_on_termination = true
}
}
}
resource "aws_iam_role" "cni" {
name = "${local.name}-cni"
assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }, Action = "sts:AssumeRoleWithWebIdentity",
Condition = { StringEquals = {
"${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-node",
"${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
} }
}] })
}
resource "aws_iam_role_policy_attachment" "cni" {
role = aws_iam_role.cni.name
policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
resource "aws_eks_addon" "cni" {
cluster_name = aws_eks_cluster.main.name
addon_name = "vpc-cni"
service_account_role_arn = aws_iam_role.cni.arn
configuration_values = jsonencode({ enableNetworkPolicy = "true" })
resolve_conflicts_on_create = "OVERWRITE"
resolve_conflicts_on_update = "PRESERVE"
depends_on = [aws_iam_role_policy_attachment.cni]
}
resource "aws_sqs_queue_policy" "dlq_tls" {
queue_url = aws_sqs_queue.dlq.id
policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Deny", Principal = "*", Action = "sqs:*", Resource = aws_sqs_queue.dlq.arn, Condition = { Bool = { "aws:SecureTransport" = "false" } } }] })
}
resource "aws_s3_bucket_policy" "reports_tls" {
bucket = aws_s3_bucket.reports.id
policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.reports.arn, "${aws_s3_bucket.reports.arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } }] })
}
