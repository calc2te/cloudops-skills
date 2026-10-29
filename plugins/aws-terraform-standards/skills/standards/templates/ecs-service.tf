# One ECS Fargate service, every name and tag generated from service_id + env.
#
# Shape of a reusable module (variables at the bottom). Take what the repository lacks; if it
# already has a service module, extend that one instead of adding a second naming path.
#
# Assumes: the cluster, execution role, VPC and an edge-tier ALB SG exist and are passed in.
# CI in the application repository registers task definitions — this code creates the first one
# only and then ignores them (reference/iam-roles.md, "Who owns the role").
#
# Org values to replace: <ORG_PATH> (e.g. /acme/)

locals {
  name = "${var.service_id}-${var.env}" # acme-checkout-api-prod — naming.md templates
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days
  tags              = { Service = var.service_id }
}

# ── Task role: one per service per environment, never shared ──
resource "aws_iam_role" "task" {
  name = "ecs-${local.name}"
  path = "<ORG_PATH>" # immutable — changing it replaces the role
  tags = { Service = var.service_id }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

# Only what the service was observed to call. null = no AWS access at all, which is a valid result.
resource "aws_iam_role_policy" "app" {
  count  = var.task_role_policy_json == null ? 0 : 1
  name   = "app"
  role   = aws_iam_role.task.id
  policy = var.task_role_policy_json
}

# ── App-tier SG: inbound only from the given SGs, outbound open (ECR, AWS APIs via NAT) ──
resource "aws_security_group" "this" {
  name_prefix = "${local.name}-ecs-"
  description = "ECS tasks of ${var.service_id} (${var.env})" # immutable — ASCII only
  vpc_id      = var.vpc_id
  tags        = { Name = "${local.name}-ecs-sg", Tier = "app", Service = var.service_id }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each                     = var.allowed_from_security_group_ids # { label = sg-id }
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  description                  = "from ${each.key}"
}

# Terraform removes AWS's default egress — without this the task cannot pull its image
resource "aws_vpc_security_group_egress_rule" "this" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "ECR, AWS APIs, external APIs via NAT"
}

# ── First task definition: CI owns every later revision ──
resource "aws_ecs_task_definition" "initial" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn # ecsexec-… — separate from the task role
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name         = var.container_name
    image        = var.image
    essential    = true
    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = var.container_name
      }
    }
  }])

  lifecycle {
    ignore_changes = all
  }
}

resource "aws_ecs_service" "this" {
  name                    = var.service_id # the cluster carries the environment
  cluster                 = var.cluster_arn
  task_definition         = aws_ecs_task_definition.initial.arn
  desired_count           = var.desired_count
  launch_type             = "FARGATE"
  propagate_tags          = "SERVICE" # without it Fargate cost is unattributed
  enable_ecs_managed_tags = true
  tags                    = { Service = var.service_id }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.this.id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [var.target_group_arn]
    content {
      target_group_arn = load_balancer.value
      container_name   = var.container_name
      container_port   = var.container_port
    }
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count] # CI deploys, autoscaling scales
  }
}

# ── Variables ──

variable "service_id" {
  description = "<product>-<deployable unit>, from the repository name. Also the Service tag."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]+$", var.service_id)) && !can(regex("-(prod|stage|qa|dev)$", var.service_id))
    error_message = "service_id is lowercase with hyphens and carries no environment suffix."
  }
  validation {
    condition     = length(var.service_id) <= 26
    error_message = "service_id over 26 chars cannot form a 32-char ALB/target group name with -stage."
  }
}

variable "env" {
  description = "Name form of the environment. The Environment tag (long form) is in default_tags."
  type        = string
  validation {
    condition     = contains(["prod", "stage", "qa", "dev"], var.env)
    error_message = "env is one of prod, stage, qa, dev."
  }
}

variable "container_name" {
  type = string
}

variable "container_port" {
  type = number
}

variable "image" {
  description = "Initial image only. CI deploys later images."
  type        = string
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "cluster_arn" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "allowed_from_security_group_ids" {
  description = "SGs allowed to reach the container port, as { label = sg-id }. Labels go into rule descriptions (ASCII)."
  type        = map(string)
  default     = {}
}

variable "target_group_arn" {
  type    = string
  default = null
}

variable "task_role_policy_json" {
  description = "Inline policy from measured usage. null = the service calls no AWS API."
  type        = string
  default     = null
}

variable "log_retention_days" {
  type    = number
  default = 30
}

output "task_role_arn" {
  description = "Hand to the application repository's task definition. Not a secret."
  value       = aws_iam_role.task.arn
}

output "security_group_id" {
  description = "Reference this from data-tier SGs the service needs to reach."
  value       = aws_security_group.this.id
}
