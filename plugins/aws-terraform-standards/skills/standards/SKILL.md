---
name: standards
description: Apply an AWS naming, tagging, security group, IAM role and security baseline standard while writing or reviewing Terraform. Use when creating or changing AWS resources in Terraform (ECS services, ALBs, target groups, security groups, IAM roles, log groups, ECR, S3, RDS, ElastiCache, SQS), naming a new service, setting provider default_tags, deciding which security group may reach which, exposing a Lambda function URL or webhook, setting ECS task definitions, ECR repositories, S3 buckets (including Terraform state) or Secrets Manager secrets so AWS Security Hub does not flag them, or reviewing a terraform plan for standard violations. Also covers Terraform behaviours that silently break these rules — forced replacement of immutable names, removed default egress, tags reverted by the next apply.
---

# AWS Terraform standards

Four standards and a security baseline. The standards share one idea: **pick one service ID per deployable unit, and let code generate every
name and tag from it.** People who name resources one by one drift apart; a resource that is born
with its tags never needs a tagging campaign.

## First: find the organisation's values

The rules are generic; the vocabulary is not. Before writing anything, look for an
`## AWS standards` block in the repository's `CLAUDE.md` / `AGENTS.md`. It should give:

| value | example |
|---|---|
| products (closed list) | `acme`, `widgets` |
| IAM role path | `/acme/` |
| `Project` tag values (closed list) | `core`, `checkout`, `infra`, `internal-tools` |
| `Team` tag values (closed list) | `platform`, `payments` |
| environments | `prod stage qa dev` → tags `production staging qa development` |
| region · account · CLI profile | `ap-northeast-2` · `123456789012` · `acme` |

If it is missing, ask for these **in one message**, offer to write the block, and do not invent tag
values — a value outside the closed list is a cost report row nobody can attribute. A ready-made
block is in [reference/configuration.md](reference/configuration.md).

## The rules, short

**Names** — [reference/naming.md](reference/naming.md)
1. Service ID = `<product>-<deployable unit>`, taken from the repository name. No environment, no
   team. It is also the `Service` tag value.
2. Every name is built from it: ALB/TG `<id>-<env>` · SG `<id>-<env>[-<role>]-sg` · IAM
   `/<org>/<kind>-<id>-<env>` · log group `/ecs/<id>-<env>` · ECR `<id>`.
3. **Always write the environment, including prod.** A wrong role or SG attaches without error.
4. Standards apply to **new** resources. Renaming an existing SG, ALB, TG or role means
   replacement — do not do it for a name.

**Tags** — [reference/tagging.md](reference/tagging.md)
5. Four required tags: `Project` · `Team` · `Environment` in provider `default_tags`; `Service` on
   each resource. Plus `ManagedBy = "terraform"`. Lowercase values only.
6. Tags set by something other than this code go in `ignore_tags`, nothing else.
7. `default_tags` does not reach everything: ECS tasks need `propagate_tags = "SERVICE"`, ASG volumes
   and ENIs need launch template `tag_specifications`.

**Security groups** — [reference/security-groups.md](reference/security-groups.md)
8. Every SG declares `Tier = edge | app | data | client`. Only `edge` accepts `0.0.0.0/0` **or
   `::/0`** inbound.
9. `app` and `data` inbound reference other SGs, not CIDRs. `data` has no outbound rule at all.
10. One SG = one tier, one workload. Use `name_prefix` and separate `aws_vpc_security_group_*_rule`
    resources; rule descriptions are ASCII only.

**IAM roles** — [reference/iam-roles.md](reference/iam-roles.md)
11. One role per workload per environment, under the org path. Task role and execution role are
    separate.
12. No `*FullAccess` managed policies, no `Resource = "*"` by default. Start narrow; widen from
    observed `AccessDenied`. Trust policies carry `aws:SourceAccount` (services) or a `sub` condition
    (OIDC).

**Security baseline** — [reference/security-baseline.md](reference/security-baseline.md) · each rule
names the Security Hub control it satisfies
13. Lambda function URL with `authorization_type = "NONE"` only for webhooks — and then verify the
    sender in code, set `reserved_concurrent_executions`, tag `Exposure = "public"` + reason.
14. ECS: `assign_public_ip = false`; containers with `readonlyRootFilesystem = true`, an explicit
    non-root `user`, and `logConfiguration`. Test read-only root in QA first — it breaks apps that
    write outside mounted volumes.
15. ECR: `IMMUTABLE` tags (deploy by commit SHA, not `:latest`) and a lifecycle policy.
16. New S3 buckets, the Terraform state bucket first: TLS-only policy, access logging, lifecycle.
    Secrets: rotation, or a `description` that says why not and who owns it.

## Before you finish: check the plan

Run `terraform plan` and read it for these, in order of how much they hurt:

- [ ] **`must be replaced`** on an SG, ALB, target group, IAM role or RDS resource — usually a
      changed `name`, `description` or `path`. Stop and say so; do not apply a rename.
- [ ] Any SG rule with `0.0.0.0/0` or `::/0` on an SG whose `Tier` is not `edge`.
- [ ] A new resource without `Service`, or with a tag value outside the closed lists.
- [ ] A new `aws_security_group` with no egress rule that is not `data` tier — Terraform removed
      AWS's default egress and the workload cannot reach ECR.
- [ ] A policy with `Resource = "*"` that is not a documented exception
      ([iam-roles.md §exceptions](reference/iam-roles.md#exceptions-where--is-the-only-option)).
- [ ] Names longer than the limit (ALB/TG 32, IAM role 64) — plan passes, apply fails.
- [ ] A new public Lambda URL, public ECS IP, container without read-only root / user / logging,
      mutable ECR repository, bucket without TLS-only policy, or secret without rotation or reason —
      full list in [security-baseline.md §plan checklist](reference/security-baseline.md#plan-checklist-additions).

[reference/pitfalls.md](reference/pitfalls.md) explains each of these and the rest of the silent
failures.

## Starting points

- [templates/providers.tf](templates/providers.tf) — `default_tags`, `ignore_tags`
- [templates/ecs-service.tf](templates/ecs-service.tf) — one ECS service with names, tags, task role
  and app-tier SG generated from `service_id` + `env`
- [templates/security-groups.tf](templates/security-groups.tf) — edge → app → data chain

Copy the shape, not the values. Where the repository already has a module that generates names,
extend it instead of adding a second naming path.

## Existing infrastructure

When bringing existing resources under Terraform, **the code adapts to the resource, not the other
way round**: import, keep the old name, and edit until `plan` says `No changes`. Add the standard
tags in a separate, tag-only change. A non-standard name on a live resource is debt to pay when the
resource is replaced for another reason.

## When the standard does not fit

Say which rule, which resource, and why — then write the exception where people will see it: in the
SG rule `description`, or a comment next to the resource. Do not keep a separate exceptions file;
nobody maintains it. If a rule keeps not fitting, that is a reason to change the standard, which is
the organisation's call, not this skill's.
