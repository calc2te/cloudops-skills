# Changelog

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
