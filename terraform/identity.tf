resource "aws_secretsmanager_secret" "keycloak" {
name = "${local.name}/keycloak"
description = "Dedicated Keycloak database credentials; values populated out-of-band"
recovery_window_in_days = 30
}
resource "aws_iam_role" "keycloak" {
name = "${local.name}-keycloak"
assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }, Action = "sts:AssumeRoleWithWebIdentity",
Condition = { StringEquals = {
"${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:vortexbird:keycloak",
"${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
} }
}] })
}
resource "aws_iam_role_policy" "keycloak" {
role = aws_iam_role.keycloak.id
policy = jsonencode({ Version = "2012-10-17", Statement = [
{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [aws_secretsmanager_secret.keycloak.arn] }
] })
}
output "keycloak_role_arn" {
value = aws_iam_role.keycloak.arn 
}
output "keycloak_secret_arn" {
value = aws_secretsmanager_secret.keycloak.arn 
}
