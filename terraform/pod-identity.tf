# Backend uses the SDK container credential provider; it does not call STS itself.
# CNI and Keycloak retain their separate IRSA roles.
data "aws_eks_addon_version" "pod_identity" {
  addon_name         = "eks-pod-identity-agent"
  kubernetes_version = var.kubernetes_version
  most_recent        = false
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = data.aws_eks_addon_version.pod_identity.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  depends_on                  = [aws_eks_node_group.main, aws_vpc_endpoint.eks_auth]
}

resource "aws_eks_pod_identity_association" "backend" {
  cluster_name         = aws_eks_cluster.main.name
  namespace            = "vortexbird"
  service_account      = "backend"
  role_arn             = aws_iam_role.backend.arn
  disable_session_tags = false
  depends_on           = [aws_eks_addon.pod_identity, aws_iam_role_policy.backend]
}

# Private EKS Auth connectivity for the node agent. Node IAM uses the already
# attached AmazonEKSWorkerNodePolicy, including eks-auth:AssumeRoleForPodIdentity.
resource "aws_security_group" "eks_auth_endpoint" {
  name        = "${local.name}-eks-auth-endpoint"
  description = "EKS Auth PrivateLink accepts TLS from workload nodes only"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "eks_auth_endpoint" {
  security_group_id            = aws_security_group.eks_auth_endpoint.id
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_endpoint" "eks_auth" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.eks-auth"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.app[*].id
  security_group_ids  = [aws_security_group.eks_auth_endpoint.id]
  private_dns_enabled = true
}
