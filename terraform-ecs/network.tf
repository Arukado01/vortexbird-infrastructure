resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "tiers" {
  for_each = {
    public-a = { zone = 0, offset = 0, tier = "public" }
    public-b = { zone = 1, offset = 1, tier = "public" }
    app-a    = { zone = 0, offset = 10, tier = "app" }
    app-b    = { zone = 1, offset = 11, tier = "app" }
    data-a   = { zone = 0, offset = 20, tier = "data" }
    data-b   = { zone = 1, offset = 21, tier = "data" }
  }
  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.zones[each.value.zone]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value.offset)
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name}-${each.key}", Tier = each.value.tier }
}

locals {
  public_subnets = [aws_subnet.tiers["public-a"].id, aws_subnet.tiers["public-b"].id]
  app_subnets    = [aws_subnet.tiers["app-a"].id, aws_subnet.tiers["app-b"].id]
  data_subnets   = [aws_subnet.tiers["data-a"].id, aws_subnet.tiers["data-b"].id]
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = local.public_subnets[count.index]
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table" "app" {
  count  = 2
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[local.production ? count.index : 0].id
  }
}

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table_association" "tiers" {
  for_each       = aws_subnet.tiers
  subnet_id      = each.value.id
  route_table_id = startswith(each.key, "public") ? aws_route_table.public.id : (startswith(each.key, "data") ? aws_route_table.data.id : aws_route_table.app[endswith(each.key, "-a") ? 0 : 1].id)
}

resource "aws_security_group" "tier" {
  for_each    = toset(["alb", "frontend", "api", "worker", "migration", "postgres", "redis"])
  name_prefix = "${local.name}-${each.key}-"
  description = "VortexBird ECS ${each.key}"
  vpc_id      = aws_vpc.main.id
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "edge" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.tier["alb"].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
}

resource "aws_vpc_security_group_egress_rule" "https" {
  for_each          = local.task_containers
  security_group_id = aws_security_group.tier[each.key].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

locals {
  private_flows = {
    alb-frontend = { source = "alb", target = "frontend", port = 8080 }
    alb-api      = { source = "alb", target = "api", port = 8080 }
    api-db       = { source = "api", target = "postgres", port = 5432 }
    worker-db    = { source = "worker", target = "postgres", port = 5432 }
    migration-db = { source = "migration", target = "postgres", port = 5432 }
    api-cache    = { source = "api", target = "redis", port = 6379 }
    worker-cache = { source = "worker", target = "redis", port = 6379 }
  }
}

resource "aws_vpc_security_group_ingress_rule" "private_flows" {
  for_each                     = local.private_flows
  security_group_id            = aws_security_group.tier[each.value.target].id
  referenced_security_group_id = aws_security_group.tier[each.value.source].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

resource "aws_vpc_security_group_egress_rule" "private_flows" {
  for_each                     = local.private_flows
  security_group_id            = aws_security_group.tier[each.value.source].id
  referenced_security_group_id = aws_security_group.tier[each.value.target].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}
