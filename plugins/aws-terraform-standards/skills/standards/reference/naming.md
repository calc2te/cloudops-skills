# Naming

> **One service ID per deployable unit; every resource name is generated from it.**

Accounts end up with several naming systems at once — `Acme`, `backend`, `ecs-acme-api-backend`,
`new-admin-alb` — because each resource was named by a different person on a different day. The fix
is not a cleverer name; it is not naming things by hand.

## Service ID

```
service ID = <product>-<deployable unit>

  product          closed list from the organisation's configuration
  internal tool    <business area>-<tool>      (employee-only tools, not a product)
  deployable unit  repository name minus the product prefix
                   + component, when one repository deploys several units
```

- **Find it, don't invent it.** The product is known; the unit is the repository name.
- Lowercase letters, digits, hyphens. **No environment** — that is a separate segment.
- **No team, no business area.** Those change; many names cannot. Tags carry them.
- The service ID **is** the `Service` tag value, on every resource of that unit.

| repository | service ID | note |
|---|---|---|
| `acme-checkout-api` | `acme-checkout-api` | already starts with the product |
| `laravel` | `acme-laravel` | generic repo name → prefix the product |
| `acme-llm-backend`, product is widgets | `widgets-llm-backend` | the **product wins** over the repo prefix |
| monorepo `acme-llm`, its traefik | `acme-llm-traefik` | add the component |

Self-check — any "no" means try again:
1. Does this ID alone say which workload it is? (`acme-backend` — which backend?)
2. Does it start with a product, or with a business area for internal tools?
3. Is the environment absent?

### Resources without a repository (data stores, shared things)

`<service ID>-<suffix>`, with exactly these suffixes:
`-db` · `-cache` · `-queue` · `-mail` · `-storage` · `-search`

Shared by several services → `<product>-<suffix>` (`acme-db`).

## Templates

`<id>` = service ID · `<env>` = `prod` `stage` `qa` `dev` · `<role>` = security group role vocabulary
(below)

| resource | template | example (`acme-checkout-api`, prod) | limit |
|---|---|---|---|
| `Service` tag | `<id>` | `acme-checkout-api` | |
| ECS service | `<id>` | `acme-checkout-api` | the cluster carries the environment |
| ECS cluster | `<product>[-<system>]-<env>` | `acme-prod` | |
| task definition family | `<id>-<env>` | `acme-checkout-api-prod` | |
| **ALB · target group** | `<id>-<env>` | `acme-checkout-api-prod` | **32 chars** — no `-alb`/`-tg` suffix |
| security group | `<id>-<env>[-<role>]-sg` | `acme-checkout-api-prod-ecs-sg` | role only if the unit has 2+ SGs |
| IAM role | `/<org>/<kind>-<id>-<env>` | `/acme/ecs-acme-checkout-api-prod` | 64 chars |
| IAM role, GitHub OIDC | `/<org>/oidc-github-<repo>-<env>` | `/acme/oidc-github-acme-checkout-api-prod` | the source is the repository |
| ECR repository | `<id>[-<component>]` | `acme-checkout-api` | shared across environments |
| log group | `/ecs/<id>-<env>` | `/ecs/acme-checkout-api-prod` | |
| SSM `.env` parameter | `<ID_UPPER_SNAKE>_<ENV>` | `ACME_CHECKOUT_API_PROD` | SecureString |
| S3 bucket | `<id>-<env>-<purpose>` | `acme-checkout-api-prod-uploads` | global — append account ID on collision |

Security group roles (only these): `alb` `nlb` `ecs` `ec2` `rds` `redis` `lambda` `vpce` `bastion`.
IAM identity kinds: [iam-roles.md](iam-roles.md#name).

**Names short, tags long.** `prod` in names, `production` in the `Environment` tag. Same thing.

## In Terraform: one place builds names

```hcl
locals {
  name = "${var.service_id}-${var.env}"         # acme-checkout-api-prod
}

resource "aws_lb_target_group" "this" {
  name = local.name                             # 32-char limit — validate service_id length
  tags = { Service = var.service_id }
}

resource "aws_cloudwatch_log_group" "this" {
  name = "/ecs/${local.name}"
  tags = { Service = var.service_id }
}
```

Validate the inputs so a bad ID fails at `plan`, not at the API:

```hcl
variable "service_id" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]+$", var.service_id)) && !can(regex("-(prod|stage|qa|dev)$", var.service_id))
    error_message = "service_id is <product>-<unit>: lowercase, hyphens, no environment suffix."
  }
  validation {
    condition     = length(var.service_id) <= 26   # ALB/TG name = <id>-<env> must fit 32 with "-stage"
    error_message = "service_id longer than 26 chars cannot form a valid ALB/target group name."
  }
}
```

## Why the environment is always written — prod too

The common habit "no suffix means prod" works for people and fails for tools. Worse, the resources
where a mix-up hurts most fail **silently**: attaching the stage SG or role to a prod task succeeds
without error, and consoles, CloudTrail and GuardDuty show only the name. A wrong cluster name fails
the deploy; a wrong role name quietly reads the wrong database.

## Scope

- **New resources only.** SG, ALB, TG, ECS cluster and IAM role names cannot be changed — renaming
  means replacement, for the benefit of one name.
- **When a resource is replaced anyway** (narrowing an SG, moving an ALB), create it to the standard.
- The `Service` tag can always be fixed — fix it whenever you touch the resource.
- If a framework (CDK, Serverless) generates names, keep its names and set the `Service` tag.
