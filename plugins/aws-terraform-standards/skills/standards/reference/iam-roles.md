# IAM roles

The usual problem is not names — it is **sharing**. One `ecs_role` used by fifteen services, carrying
`SecretsManagerReadWrite` and `AmazonSSMFullAccess`, means: one compromised app reads every secret in
the account, CloudTrail cannot say which service did what, and no single service can be narrowed.

Moving a workload off static access keys onto roles is a separate, riskier job with its own
procedure — the **aws-keyless** plugin in the same marketplace covers it. This page is about writing
roles in Terraform from the start.

## Path: what you made vs. what AWS made

```
arn:aws:iam::<ACCOUNT>:role/<org>/ecs-acme-checkout-api-prod
                            └ ours └ what it is
```

Use the organisation's IAM **path**, not a name prefix. The API lists by path
(`aws iam list-roles --path-prefix /acme/`), policies can match on it
(`arn:aws:iam::*:role/acme/*` in a permissions boundary or `iam:PassRole` condition), and it costs no
characters of the 64-character name.

Path and name are **immutable**. Changing either in Terraform replaces the role — and every
reference to its ARN.

## Name

```
<identity kind>-<source or service ID>-<env>      lowercase kebab-case
```

| prefix | identity | trusted principal |
|---|---|---|
| `sso-` | a person, via an external IdP | SAML / OIDC provider |
| `oidc-` | an external machine (CI, a PaaS) | OIDC provider |
| `ecs-` | ECS **task** role — the app calling AWS | `ecs-tasks.amazonaws.com` |
| `ecsexec-` | ECS **execution** role — image pull, logs, secrets injection | `ecs-tasks.amazonaws.com` |
| `ec2-` | EC2 instance profile | `ec2.amazonaws.com` |
| `lambda-` | Lambda execution role | `lambda.amazonaws.com` |
| `svc-` | other service-to-service (events, scheduler, firehose…) | that service |

Examples: `ecs-acme-checkout-api-prod` · `ecsexec-acme-prod` · `oidc-github-acme-checkout-api-prod` ·
`lambda-acme-report-stage` · `sso-google-admin`

Environment suffix always (except `sso-` and genuinely environment-less roles): the name is the
permission boundary, and attaching the wrong one succeeds silently.

Classification (Project, Team) goes in tags, not the name.

## Permissions

1. **One role per workload per environment.** Never share. A role per service is what makes Access
   Advisor and CloudTrail tell you what each one uses.
2. **No `*FullAccess`**, and in particular never `SecretsManagerReadWrite`, `AmazonSSMFullAccess`,
   `AdministratorAccess`, `AmazonS3FullAccess`, `AmazonDynamoDBFullAccess`.
   `AmazonBedrockLimitedAccess` is not limited — it includes creating inference profiles and
   marketplace subscriptions. Write inline statements instead.
3. **No `Resource = "*"` by default.** Scope to the workload's own bucket, table, parameter path:
   `arn:aws:ssm:<region>:<account>:parameter/<id>/<env>/*`.
4. **Start narrow, widen from evidence.** An `AccessDenied` names exactly what to add; an over-broad
   policy tells you nothing. Plenty of services need no policy at all.
5. **Execution role ≠ task role.** ECS uses the execution role to start the task; the app uses the
   task role. `AmazonECSTaskExecutionRolePolicy` on a task role is the sign they were mixed up. One
   execution role per cluster-environment is fine; task roles are per service.

### Exceptions where `*` is the only option

Write a comment next to the statement saying so.

| action | why |
|---|---|
| `ssmmessages:*Channel` (ECS Exec) | no resource-level permissions |
| `ecr:GetAuthorizationToken` | no resource-level permissions |
| `cloudwatch:PutMetricData` | no resource-level permissions — restrict with `cloudwatch:namespace` condition |
| `xray:PutTraceSegments`, `xray:PutTelemetryRecords` | no resource-level permissions |

## Trust policies

Service roles — prevent confused deputy:

```hcl
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "task" {
  name = "ecs-${var.service_id}-${var.env}"
  path = "/acme/"
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
```

GitHub Actions OIDC — without a `sub` condition **any repository on GitHub** can assume the role:

```hcl
Condition = {
  StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
  StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:<org>/<repo>:ref:refs/heads/main" }
}
```

One OIDC role per repository and environment; the trust lists the exact deploy branches.

People (SAML) — `SAML:aud` condition, and a session length no longer than needed.

## Who owns the role vs. who owns the task definition

A common split: infrastructure code owns the ECS service and its task **role**; the application
repository's CI registers task **definitions** on every deploy. Then in Terraform:

```hcl
resource "aws_ecs_service" "this" {
  lifecycle { ignore_changes = [task_definition, desired_count] }
}
```

and the role ARN is handed to the app repository once (it is not a secret). Changing the role in the
console, or the task definition in Terraform, is undone by the other side's next run.
