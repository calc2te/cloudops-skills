---
name: migrate
description: Replace static AWS access keys with roles and short-lived credentials. Use when a workload authenticates with AWS_ACCESS_KEY_ID (in .env, a container image, CI secrets, or a developer laptop) and should use an ECS task role, EC2 instance profile, Lambda execution role, GitHub Actions OIDC, or an SSO profile instead. Also covers scoping least-privilege IAM policies from measured usage, and finding hidden dependencies that break after a credential switch.
---

# Replace static AWS keys with roles

Every AWS compute platform can authenticate without a long-lived key. The hard parts are the same
everywhere: nobody knows what the workload actually calls, a shared role cannot be narrowed safely,
and one wrong step takes production down.

## Start by asking

Before measuring anything, ask the user the questions in
[reference/ask-the-user.md](reference/ask-the-user.md) — **in one batch**, each with a reason and a
default. A person answers in seconds what takes half an hour to infer.

The most valuable one: **"Is the application code available?"** If it is, scan it first — it names
every AWS client, bucket, table, queue and scheduled job, including paths too rare to appear in
CloudTrail. Measurement then becomes a cross-check instead of the only source.

Look up what you can yourself (cluster, task definition, current role) instead of asking. Check
things people rarely know (SES configuration sets, resource policies) yourself and report them.

**Trace every key the app uses back to its IAM user and read that user's permissions.** If the app
authenticates with a key, *those* are the permissions it runs with today — the attached role is
bypassed. They are the ceiling for the new role, and the baseline for showing what the migration
removed ([measuring-usage.md §2](reference/measuring-usage.md#2-inspect-the-key-being-replaced--its-permissions-are-what-the-app-runs-with-today)).

## Choose the pace

Decide this right after the answers come back — the criticality and schedule questions settle it.
Getting it wrong is how a careful migration still breaks production.

| | **One step** | **Two phases** |
|---|---|---|
| when | small workload, few AWS services, no scheduled jobs you cannot exercise, easy to observe | business-critical, many services, cron/queue workers, monthly jobs, revenue or email paths |
| identity switch | new role with a **narrow** policy | new role with the **old permissions copied** |
| permission narrowing | at the same time | after an observation window that covers the longest schedule |
| risk | a missed permission breaks something | none from permissions in phase 1 |

**Why two phases**: a credential switch and a permission cut are two different risks. Doing them
together means a failure could be either — and a missed permission often only shows up in a
scheduled job hours or weeks later. Phase 1 changes *who* the workload is, with identical rights,
so nothing can break for lack of permission. Phase 2 narrows from **observed** evidence
(CloudTrail, Access Advisor, IAM Access Analyzer policy generation), after every daily, weekly and
monthly path has run at least once.

*Seen in practice*: a one-step migration passed every check on deploy day. The next morning a
daily newsletter failed for every subscriber — the SES identity had a default configuration set that
needed its own permission, invisible in the code and absent from CloudTrail.

When unsure, choose two phases. The cost is a month of patience; the saving is an incident.

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

- [reference/ask-the-user.md](reference/ask-the-user.md) — what to ask up front, what to look up
  instead, and a ready-made opening message.
- [reference/conventions.md](reference/conventions.md) — role paths, naming, policy rules, and the
  action mappings people get wrong.
- [reference/pitfalls.md](reference/pitfalls.md) — failures that happen **silently**.
- [reference/hidden-dependencies.md](reference/hidden-dependencies.md) — what neither code review
  nor CloudTrail shows: SES configuration sets, resource policies naming the old user, KMS keys,
  scheduled jobs, presigned URL lifetimes. **Run it before narrowing anything.**
- [reference/measuring-usage.md](reference/measuring-usage.md) — how to learn what a workload
  actually calls instead of guessing a policy.

## The rules that survive every platform

**1. Order: grant the new identity first, remove the old key second.**
Attach the role, deploy, confirm it starts — *then* strip the key and deploy again. Reversed, the
workload runs with no credentials at all.

**2. The SDK finds credentials by itself — stop handing them over.**

    environment variables → ~/.aws profile → container/instance role → instance metadata

Anything your code passes explicitly wins over the role. So pass nothing. And do **not** write
"use the key if set, otherwise the role" — that branch is how a key quietly comes back later.

**3. Policies come from measurement, not imagination.**
Pick statements from [templates/policy-snippets.md](templates/policy-snippets.md) for the services
the measurement showed — and no others. Plenty of workloads need **no policy at all**; that is a
result, not a mistake. A denial names exactly what to add; an over-broad policy tells you nothing.

**4. Verification must cover every path, not just the request path.**
Web requests, queue workers and scheduled jobs often share one container but run at very different
times. A deploy-day check exercises the first and misses the rest. List the schedules
([hidden-dependencies.md §4](reference/hidden-dependencies.md#4-scheduled-jobs-and-background-workers-)) and make
sure each has run under the new identity before you call the migration done.

**5. Alert on denials before you narrow — not after someone notices.**
Wire [templates/denial-alarm.tf](templates/denial-alarm.tf) first: an `AccessDenied` for the new role
should page within a minute, not surface the next morning as a user complaint. Rolling back a
policy line takes seconds once you know.

**6. Ship a way to check.**
A diagnostics endpoint or command that prints the calling identity plus a pass/fail per service
([FastAPI](templates/diagnostics-fastapi.py) · [Laravel](templates/diagnostics-laravel.php)) turns
"did it work?" into something the owning team answers without you. Add it *before* migrating.

## Rolling this out across an account

One workload at a time, smallest and least critical first — let the procedure prove itself where a
mistake is cheap. Track the number of workloads still on shared roles or static keys: it is the only
honest progress metric, and it makes the work visible to people who are not doing it.
