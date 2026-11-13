resource "aws_iam_role" "eks" {
name = "${local.name}-eks"
assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy_attachment" "eks" {
role = aws_iam_role.eks.name
policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}
resource "aws_cloudwatch_log_group" "eks" {
name = "/aws/eks/${local.name}/cluster"
retention_in_days = local.production ? 90 : 14
}
resource "aws_eks_cluster" "main" {
name = local.name
role_arn = aws_iam_role.eks.arn
version = var.kubernetes_version
enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
encryption_config {
resources = ["secrets"]
provider {
key_arn = aws_kms_key.eks.arn
}
}
access_config {
authentication_mode = "API"
bootstrap_cluster_creator_admin_permissions = false 
}
vpc_config {
subnet_ids = aws_subnet.app[*].id
endpoint_private_access = true
endpoint_public_access = true
public_access_cidrs = var.eks_public_access_cidrs
}
depends_on = [aws_iam_role_policy_attachment.eks, aws_cloudwatch_log_group.eks]
}
resource "aws_eks_access_entry" "administrator" {
cluster_name = aws_eks_cluster.main.name
principal_arn = var.admin_role_arn
type = "STANDARD"
}
resource "aws_eks_access_policy_association" "administrator" {
cluster_name = aws_eks_cluster.main.name
principal_arn = aws_eks_access_entry.administrator.principal_arn
policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
access_scope {
type = "cluster" 
}
}
resource "aws_iam_role" "nodes" {
name = "${local.name}-nodes"
assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy_attachment" "nodes" {
for_each = toset(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly"])
role = aws_iam_role.nodes.name
policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}
resource "aws_eks_node_group" "main" {
cluster_name = aws_eks_cluster.main.name
node_group_name = "workloads"
node_role_arn = aws_iam_role.nodes.arn
subnet_ids = aws_subnet.app[*].id
instance_types = var.node_instance_types
capacity_type = "ON_DEMAND"
launch_template {
id = aws_launch_template.nodes.id
version = aws_launch_template.nodes.latest_version
}
scaling_config {
desired_size = local.production ? 3 : 2
min_size = 2
max_size = local.production ? 12 : 3 
}
update_config {
max_unavailable = 1 
}
depends_on = [aws_iam_role_policy_attachment.nodes, aws_route_table_association.app, aws_eks_addon.cni]
}
data "tls_certificate" "eks" {
url = aws_eks_cluster.main.identity[0].oidc[0].issuer 
}
resource "aws_iam_openid_connect_provider" "eks" {
url = aws_eks_cluster.main.identity[0].oidc[0].issuer
client_id_list = ["sts.amazonaws.com"]
thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}
resource "aws_iam_role" "backend" {
name = "${local.name}-backend"
assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
Effect = "Allow", Principal = { Service = "pods.eks.amazonaws.com" }, Action = ["sts:AssumeRole", "sts:TagSession"],
Condition = { StringEquals = {
"aws:RequestTag/eks-cluster-arn" = aws_eks_cluster.main.arn,
"aws:RequestTag/kubernetes-namespace" = "vortexbird",
"aws:RequestTag/kubernetes-service-account" = "backend"
} }
}] })
}
resource "aws_iam_role_policy" "backend" {
role = aws_iam_role.backend.id
policy = jsonencode({ Version = "2012-10-17", Statement = [
{ Effect = "Allow", Action = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"], Resource = [aws_sqs_queue.events.arn, aws_sqs_queue.dlq.arn] },
{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [aws_secretsmanager_secret.application.arn] }
] })
}
resource "aws_ecr_repository" "images" {
for_each = toset(["backend", "frontend"])
name = "${local.name}/${each.value}"
image_tag_mutability = "IMMUTABLE"
image_scanning_configuration {
scan_on_push = true 
}
encryption_configuration {
encryption_type = "AES256" 
}
}
resource "aws_ecr_lifecycle_policy" "images" {
for_each = aws_ecr_repository.images
repository = each.value.name
policy = jsonencode({ rules = [{ rulePriority = 1, description = "Expire untagged images after 7 days", selection = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }, action = { type = "expire" } }] })
}
