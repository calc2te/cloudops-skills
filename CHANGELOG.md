# Changelog

## 0.4.0 — inspect the key being replaced

Correction to 0.2.0. Two-phase migration said "copy the permissions the workload has today" and
pointed at the attached task role. But when an app authenticates with a static key, the SDK uses the
key and **the attached role is bypassed** — its policies say nothing about what the app actually
does. The permissions in effect are the key's IAM user's.

- `measuring-usage.md` §2 rewritten: resolve each key (including secondary ones like `DYNAMODB_KEY`)
  to its IAM user; read attached, inline and group policies plus any permissions boundary; compare
  **granted vs. used** (Access Advisor, CloudTrail); detect keys that no longer exist (the path using
  them is already broken); handle shared keys. Table of which permissions are "in effect today".
- `playbooks/ecs.md` Step 2 (two-phase): keep the **key user's** permissions, not the role's; union
  if both are used; nothing for a deleted key.
- `pitfalls.md` #13: the attached role is not necessarily what the app runs with.
- `ask-the-user.md` / `SKILL.md`: ask whether keys are shared; trace keys to users yourself.

## 0.3.0 — ask before you dig

From first use in the field: the skill spent effort reconstructing things a person could answer in
seconds — above all, *where the code is*. Scanning the code finds rare paths CloudTrail never shows.

- **New** `reference/ask-the-user.md`: what only a person knows (code location, criticality,
  schedules, user-facing features, deploy path, approver), what to look up instead, and what to
  check yourself because people rarely know it. Ask once, in one batch, with defaults.
- `SKILL.md`: new **Start by asking** step before choosing the pace.
- Code is now the **primary** source of what a workload calls; CloudTrail is the cross-check
  (`measuring-usage.md`, `playbooks/ecs.md` Step 1). Results must say what was measured vs. confirmed.
- Every playbook's Step 0 starts with the platform-specific questions to ask.

## 0.2.0 — two-phase migrations and hidden dependencies

Learned from a production incident: a one-step migration passed every deploy-day check, and the
next morning's newsletter failed for all subscribers. The SES identity had a default configuration
set that needed its own permission — invisible in code, absent from CloudTrail, and on a path that
only ran once a day.

- **Choose the pace** (SKILL.md): one step for small workloads; **two phases** for critical ones —
  switch identity with permissions copied, observe a full schedule cycle, then narrow.
- **New** `reference/hidden-dependencies.md`: SES default configuration sets, resource policies
  naming the old principal, KMS keys, scheduled jobs and workers, presigned URL lifetimes, ECS Exec,
  data-plane gaps in CloudTrail — each with a check command.
- **New** `templates/denial-alarm.tf`: CloudTrail→EventBridge and log-metric alarms on authorization
  failures, to wire *before* narrowing.
- `policy-snippets.md`: SES statement now includes the configuration-set ARN and how to detect it.
- `measuring-usage.md`: IAM Access Analyzer policy generation as a draft source for phase 2.
- `pitfalls.md`: #11 invisible permissions, #12 combining identity switch with narrowing.
- `playbooks/ecs.md`: two-phase path; verification extends through scheduled jobs.

## 0.1.0

Initial release: ECS playbook (battle-tested), EC2 / Lambda / GitHub OIDC / local-dev playbooks,
conventions, pitfalls, measuring-usage, Terraform and diagnostics templates.
