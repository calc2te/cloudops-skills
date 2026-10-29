# Security groups

> **The axis is not "which port is open" but "which tier faces the internet".**

Count open ports and an ordinary account shows dozens of violations, most of them an ALB's 80 and
443. The real exposure drowns. Classify by tier and the same account shows one or two — the ones
that matter.

## Tiers

Declare with the `Tier` tag. Without it no other rule can be judged.

| Tier | what | inbound |
|---|---|---|
| `edge` | ALB, NLB, CloudFront origin | **the only tier that accepts the internet** (80, 443) |
| `app` | ECS task SG (awsvpc), standalone EC2 workload | from `edge` SGs, or other `app` SGs, by reference |
| `data` | RDS/Aurora, ElastiCache, OpenSearch | from `app` SGs, by reference |
| `client` | Lambda VPC ENIs, ECS-on-EC2 instance SG when tasks have their own SG | **none** — outbound only |

ECS on EC2 with awsvpc has two layers: the task SG is `app`, the instance SG is `client`. One SG
must not play both.

## Six rules

**1. Every SG declares `Tier`.** Untagged is counted as *unclassified*, not as a violation — a
permanently red metric hides the rules that matter.

**2. Only `edge` has `0.0.0.0/0` or `::/0` inbound.** Judge both together. Closing the IPv4 rule and
missing the IPv6 one is how "we fixed it" turns into an incident. SSH needs no separate rule: it is
covered here.

**3. `app` and `data` inbound use SG references.** CIDRs are for what cannot be referenced: office
`/32`s, a SaaS provider's fixed IPs, VPN, peered regions, services outside the VPC (Lightsail cannot
be referenced). Gateway endpoints use prefix lists and are fine.

**4. Only `data` forbids outbound `0.0.0.0/0`.** A database has no reason to reach the internet, and
this is the one place that actually cuts an exfiltration path. Applying it to `app` breaks Fargate's
access to ECR, S3, CloudWatch and Secrets Manager and produces a hundred permanent exceptions.

**5. One SG = one tier, one workload.** Shared SGs are where real exposure comes from: one
"allow everything" SG attached to a forgotten instance and a Lambda at once. Ports were not the
problem; sharing was.

**6. Exceptions go in the rule's `description`.** `"partner webhook fixed IP - jane - 2026-12-31"`.
No separate exceptions file. The description must be under 256 characters and ASCII only
(`a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*`) — non-ASCII passes `plan` and fails `apply`.

## Terraform shape

```hcl
resource "aws_security_group" "app" {
  name_prefix = "${local.name}-ecs-"                     # not `name` — see below
  description = "ECS tasks of ${var.service_id} (${var.env})"   # immutable: changing it replaces the SG
  vpc_id      = var.vpc_id
  tags = {
    Name    = "${local.name}-ecs-sg"                    # what the console list shows
    Tier    = "app"
    Service = var.service_id
  }
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  description                  = "from public ALB"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "ECR, AWS APIs, external APIs via NAT"
}
```

Full chain: [templates/security-groups.tf](../templates/security-groups.tf).

### `name_prefix`, not `name`

`GroupName` and `Description` cannot be changed after creation — there is no API for it. Terraform
therefore **replaces** the SG when either changes. With a fixed `name`, the replacement cannot be
created before the old one is destroyed (names are unique per VPC), so `create_before_destroy`
fails, and destroying first detaches every ENI. `name_prefix` adds a random suffix that makes the
swap possible. Put the readable name in the `Name` tag.

For SGs created by hand, outside code, `GroupName` = `Name` tag = `<id>-<env>[-<role>]-sg`.

### Separate rule resources, not inline blocks

Use `aws_vpc_security_group_ingress_rule` / `_egress_rule`. Inline `ingress {}` / `egress {}` blocks
cannot be mixed with rule resources on the same SG (each side keeps deleting the other's rules), and
SGs that reference each other create a dependency cycle when rules are inline. Create all SGs first,
rules second.

### Terraform removes the default egress

AWS gives a new SG an allow-all egress rule; Terraform deletes it on creation. An SG declared with no
egress rule has **no outbound at all**.
- `data` tier: that is exactly what rule 4 wants — declare nothing.
- every other tier: declare the egress explicitly, or the task cannot pull its image.

### Don't edit IaC-managed rules in the console

The next `apply` reverts them. A reverted tag is a reporting problem; a reverted rule closes a port.

## What is deliberately not a rule

| not a rule | why |
|---|---|
| "no public 80/443" | rule 2 already catches the non-edge cases; the rest are load balancers |
| "delete unused SGs" | deletion is irreversible and IaC recreates them; track as cleanup, not a KPI |
| "no SSH anywhere" | closing 22 before SSM Session Manager covers every instance removes the only access path |

## Rolling this out on an existing account

Freeze a baseline: record every SG that exists today as exempt, and count only new ones. A list that
starts at zero makes the first violation visible; a list that starts at a hundred is ignored.
Removing an SG from the baseline means it was cleaned up, and only a person does that.
