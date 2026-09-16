---
name: migrate
description: Replace static AWS access keys with roles and short-lived credentials. Use when a workload authenticates with AWS_ACCESS_KEY_ID (in .env, a container image, CI secrets, or a developer laptop) and should use an ECS task role, EC2 instance profile, Lambda execution role, GitHub Actions OIDC, or an SSO profile instead. Also covers scoping least-privilege IAM policies from measured usage.
---

# Replace static AWS keys with roles

Every AWS compute platform can authenticate without a long-lived key. The hard parts are the same
everywhere: nobody knows what the workload actually calls, a shared role cannot be narrowed safely,
and one wrong step takes production down.

## Pick the playbook

| What holds the key today | Identity to move to | Playbook |
|---|---|---|
| ECS service (`.env` in the image, task definition env vars) | task role | [playbooks/ecs.md](playbooks/ecs.md) ← battle-tested |
| EC2 instance (userdata, `~/.aws`, app config) | instance profile | [playbooks/ec2.md](playbooks/ec2.md) |
| Lambda function (env vars) | execution role | [playbooks/lambda.md](playbooks/lambda.md) |
| GitHub Actions (`secrets.AWS_ACCESS_KEY_ID`) | OIDC federation | [playbooks/github-oidc.md](playbooks/github-oidc.md) |
| Developer laptop (`~/.aws/credentials` static key) | SSO / SAML short-lived session | [playbooks/local-dev.md](playbooks/local-dev.md) |

Adding a platform? Copy [playbooks/_template.md](playbooks/_template.md) — the shape is fixed on
purpose.

## Read these first, whatever the platform

- [reference/conventions.md](reference/conventions.md) — role paths, naming, policy rules, and the
  action mappings people get wrong (`Converse` → `bedrock:InvokeModel`, listing on the bucket ARN…).
- [reference/pitfalls.md](reference/pitfalls.md) — ten failures that happen **silently**. Read this
  before touching anything; every item cost someone real time.
- [reference/measuring-usage.md](reference/measuring-usage.md) — how to learn what a workload
  actually calls instead of guessing a policy.

## The four rules that survive every platform

**1. Order: grant the new identity first, remove the old key second.**
Attach the role, deploy, confirm it starts — *then* strip the key and deploy again. Reversed, the
workload runs with no credentials at all. This is the single most common way these migrations fail.

**2. The SDK finds credentials by itself — stop handing them over.**

    environment variables → ~/.aws profile → container/instance role → instance metadata

Anything your code passes explicitly wins over the role. So pass nothing. And do **not** write
"use the key if set, otherwise the role" — that branch is how a key quietly comes back later.

**3. Policies come from measurement, not imagination.**
Actions from the code, resource ARNs from config and CloudTrail. Start narrow: a denial names
exactly what to add, while an over-broad policy tells you nothing and protects nothing.

**4. Ship a way to check.**
A diagnostics endpoint or command that prints the calling identity plus a pass/fail per service
([FastAPI](templates/diagnostics-fastapi.py) · [Laravel](templates/diagnostics-laravel.php)) turns
"did it work?" into something the owning team answers without you. Add it *before* migrating so you
have a before/after.

## Rolling this out across an account

One workload at a time. A role shared by many services cannot be tightened safely until each one
has its own — so split first (copy the same permissions; risk is zero), let CloudTrail and Access
Advisor accumulate per-role evidence, then narrow a month later.

Track the remaining shared-role users as a number. It is the only honest progress metric, and it
makes the work visible to people who are not doing it.
