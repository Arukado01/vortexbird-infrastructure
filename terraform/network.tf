resource "aws_vpc" "main" {
cidr_block = "10.73.0.0/16"
enable_dns_hostnames = true
enable_dns_support = true
tags = { Name = local.name }
}
resource "aws_subnet" "public" {
count = 2
vpc_id = aws_vpc.main.id
availability_zone = local.azs[count.index]
cidr_block = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
map_public_ip_on_launch = false
tags = { Name = "${local.name}-public-${count.index}", "kubernetes.io/role/elb" = "1" }
}
resource "aws_subnet" "app" {
count = 2
vpc_id = aws_vpc.main.id
availability_zone = local.azs[count.index]
cidr_block = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 10)
tags = { Name = "${local.name}-app-${count.index}", "kubernetes.io/role/internal-elb" = "1" }
}
resource "aws_subnet" "data" {
count = 2
vpc_id = aws_vpc.main.id
availability_zone = local.azs[count.index]
cidr_block = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 20)
tags = { Name = "${local.name}-data-${count.index}" }
}
resource "aws_internet_gateway" "main" {
vpc_id = aws_vpc.main.id 
}
resource "aws_route_table" "public" {
vpc_id = aws_vpc.main.id
route {
cidr_block = "0.0.0.0/0"
gateway_id = aws_internet_gateway.main.id 
}
}
resource "aws_route_table_association" "public" {
count = 2
subnet_id = aws_subnet.public[count.index].id
route_table_id = aws_route_table.public.id
}
resource "aws_eip" "nat" {
count = local.nat_count
domain = "vpc" 
}
resource "aws_nat_gateway" "main" {
count = local.nat_count
allocation_id = aws_eip.nat[count.index].id
subnet_id = aws_subnet.public[count.index].id
depends_on = [aws_internet_gateway.main]
}
resource "aws_route_table" "app" {
count = 2
vpc_id = aws_vpc.main.id
route {
cidr_block = "0.0.0.0/0"
nat_gateway_id = aws_nat_gateway.main[local.production ? count.index : 0].id 
}
}
resource "aws_route_table_association" "app" {
count = 2
subnet_id = aws_subnet.app[count.index].id
route_table_id = aws_route_table.app[count.index].id
}
resource "aws_route_table" "data" {
vpc_id = aws_vpc.main.id 
}
resource "aws_route_table_association" "data" {
count = 2
subnet_id = aws_subnet.data[count.index].id
route_table_id = aws_route_table.data.id
}
resource "aws_vpc_endpoint" "s3" {
vpc_id = aws_vpc.main.id
service_name = "com.amazonaws.${var.region}.s3"
vpc_endpoint_type = "Gateway"
route_table_ids = aws_route_table.app[*].id
}
resource "aws_security_group" "database" {
name = "${local.name}-database"
vpc_id = aws_vpc.main.id
description = "Only EKS workload nodes may reach PostgreSQL" 
}
resource "aws_security_group" "redis" {
name = "${local.name}-redis"
vpc_id = aws_vpc.main.id
description = "Only EKS workload nodes may reach TLS Redis" 
}
resource "aws_vpc_security_group_ingress_rule" "postgres" {
security_group_id = aws_security_group.database.id
referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
from_port = 5432
to_port = 5432
ip_protocol = "tcp"
}
resource "aws_vpc_security_group_ingress_rule" "redis" {
security_group_id = aws_security_group.redis.id
referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
from_port = 6379
to_port = 6379
ip_protocol = "tcp"
}
