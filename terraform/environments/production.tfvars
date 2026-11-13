environment = "production"
region = "us-east-2"
node_instance_types = ["m7i.large"]
db_instance_class = "db.t4g.medium"
redis_node_type = "cache.t4g.small"
# Supply verified kubernetes_version, admin_role_arn, eks_public_access_cidrs and redis_auth_token separately.
