# Tagging

AWS bills per resource. Without tags, nobody can say whose money it was — and the bill records the
tag value **at the time of use**, so a tag fixed next month does not fix this month. The only reliable
moment to tag is creation, which means **the code must carry the tags**.

## Required

| key | answers | values | set where |
|---|---|---|---|
| `Project` | which line of business pays | closed list (configuration) | provider `default_tags` |
| `Team` | who operates it | closed list (configuration) | provider `default_tags` |
| `Environment` | which environment | `production` `staging` `qa` `development` | provider `default_tags` |
| `Service` | which deployable unit | service ID ([naming.md](naming.md)) | **each resource** |

Recommended: `ManagedBy` — `terraform` (lowercase; `Terraform` and `terraform` are two values in a
cost report).

All values lowercase with hyphens. No slashes, spaces or capitals.

One Terraform root usually means one Project, one Team and one Environment — so those three belong
in the provider. `Service` differs per resource, so it is set per resource, from the same variable
that builds the name.

```hcl
provider "aws" {
  default_tags {
    tags = {
      Project     = "core"
      Team        = "platform"
      Environment = "production"
      ManagedBy   = "terraform"
    }
  }
  ignore_tags {
    keys = ["Lifecycle"]   # set by cleanup scripts, not by this code
  }
}

resource "aws_ecs_service" "this" {
  tags = { Service = var.service_id }
}
```

## `Service` values

> **The value alone must say which workload it is.** `db` — which one? `checkout-db` — that one.

| resource | where the value already is |
|---|---|
| ECS service, task, ALB, target group, log group | the service ID of the unit |
| data store (RDS, ElastiCache, SQS, SES, S3) | owner's service ID + `-db` `-cache` `-queue` `-mail` `-storage` `-search` |
| shared data store | `<product>-<suffix>` |
| security group | what it **wraps** (`checkout-rds-sg` → `acme-checkout-db`) |
| alarm, scaling policy | what it **controls** |
| environment-wide (cluster, namespace, shared ALB) | a name for the shared thing (`acme-ecs`, `acme-ingress`) |

Generic values that always need a prefix:

```
ai api app backend cache cdn cluster db default dev front frontend mail main
prod proxy queue server service session stage storage test web worker
```

Names that identify a specific piece of software (`traefik`, `metabase`, `grafana`) can stand alone.

The value does not have to be unique across the account; reports join on `(Project, Service)`.

## Where `default_tags` does not reach

| resource | what is missed | fix |
|---|---|---|
| ECS tasks | Fargate cost unattributed — often the biggest line | `propagate_tags = "SERVICE"` + `enable_ecs_managed_tags = true` on `aws_ecs_service` |
| instances launched by an ASG | instance tags | `tag { propagate_at_launch = true }` on the ASG, or launch template |
| EBS volumes and ENIs of ASG instances | everything — `propagate_at_launch` covers instances only | launch template `tag_specifications` for `volume` and `network-interface` |
| resources created by AWS on your behalf (ENIs of Lambda, snapshots) | varies | usually acceptable; snapshots copy parent tags |

```hcl
resource "aws_launch_template" "this" {
  dynamic "tag_specifications" {
    for_each = ["instance", "volume", "network-interface"]
    content {
      resource_type = tag_specifications.value
      tags          = merge(data.aws_default_tags.current.tags, { Service = var.service_id })
    }
  }
}

data "aws_default_tags" "current" {}
```

## `ignore_tags` — narrow

List only keys that **another process** writes on purpose (a cleanup script's `Lifecycle`, a
deprecated key you no longer manage). Everything else stays under Terraform's control so drift
shows up in `plan`.

Do not list a key in both `ignore_tags` and a resource's `tags`: the resource value is never
written back, and the two disagree silently.

## Don't fix tags in the console

The next `apply` reverts them. If a tag is wrong, it is wrong in code.

## Optional: delete candidates

`Lifecycle = delete-candidate` marks a resource that will be removed but is still referenced. One
key, no date or reason tags — the reason lives in the ticket. Usually set by hand or a script, which
is why it belongs in `ignore_tags`.

## Not worth tagging

- ECS task definitions (versioned, short-lived)
- Automated snapshots (copy parent tags, expire)
- Shared networking: VPC, subnets, route tables, internet gateway — not attributable to one service
