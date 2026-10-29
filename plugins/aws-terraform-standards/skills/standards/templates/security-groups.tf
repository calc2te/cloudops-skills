# edge → app → data, one SG per tier per workload.
#
#   internet ──80/443──▶ alb-sg (edge) ──port──▶ ecs-sg (app) ──5432──▶ rds-sg (data)
#
# Rules: reference/security-groups.md. Every SG: name_prefix, Name/Tier/Service tags,
# create_before_destroy, rules as separate resources, descriptions in ASCII.

locals {
  name = "${var.service_id}-${var.env}"
  db   = "${var.service_id}-db" # Service value of the data store: owner + suffix
}

# ── edge: the only tier that accepts the internet ──
resource "aws_security_group" "alb" {
  name_prefix = "${local.name}-alb-"
  description = "Public ALB of ${var.service_id} (${var.env})"
  vpc_id      = var.vpc_id
  tags        = { Name = "${local.name}-alb-sg", Tier = "edge", Service = var.service_id }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_ipv4" {
  for_each          = { http = 80, https = 443 }
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = "0.0.0.0/0"
  description       = "public ${each.key}"
}

# IPv6 is a separate rule. Only add it on edge, and only if the ALB is dualstack.
resource "aws_vpc_security_group_ingress_rule" "alb_ipv6" {
  for_each          = var.dualstack ? { http = 80, https = 443 } : {}
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv6         = "::/0"
  description       = "public ${each.key} ipv6"
}

# ALB egress: only to the app SG, only the container port
resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  description                  = "to ${var.service_id} tasks"
}

# ── app: inbound by SG reference only ──
resource "aws_security_group" "app" {
  name_prefix = "${local.name}-ecs-"
  description = "ECS tasks of ${var.service_id} (${var.env})"
  vpc_id      = var.vpc_id
  tags        = { Name = "${local.name}-ecs-sg", Tier = "app", Service = var.service_id }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  description                  = "from public ALB"
}

# Terraform removed AWS's default egress; app tier needs it back (ECR, AWS APIs, NAT)
resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "ECR, AWS APIs, external APIs via NAT"
}

# ── data: inbound from app by reference, NO egress rule at all ──
resource "aws_security_group" "db" {
  name_prefix = "${local.db}-${var.env}-rds-"
  description = "Database of ${var.service_id} (${var.env})"
  vpc_id      = var.vpc_id
  tags        = { Name = "${local.db}-${var.env}-sg", Tier = "data", Service = local.db }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "from ${var.service_id} tasks"
}

# An exception that cannot be an SG reference: say why, who, until when — in the description.
# resource "aws_vpc_security_group_ingress_rule" "db_from_office" {
#   security_group_id = aws_security_group.db.id
#   ip_protocol       = "tcp"
#   from_port         = 5432
#   to_port           = 5432
#   cidr_ipv4         = "203.0.113.10/32"
#   description       = "office NAT for migration - jane - 2026-12-31"
# }

variable "service_id" {
  type = string
}

variable "env" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "container_port" {
  type = number
}

variable "dualstack" {
  type    = bool
  default = false
}
