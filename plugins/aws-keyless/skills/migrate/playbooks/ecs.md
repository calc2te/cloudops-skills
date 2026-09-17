# ECS: static keys → per-service task role

Run end to end on production services. **The order is the whole trick** — reverse it and you ship a
container with neither a key nor a role, and the service dies.

Prerequisites: [conventions](../reference/conventions.md) for naming and policy rules,
[pitfalls](../reference/pitfalls.md) open beside you — every item there is a silent failure.

**Decide the pace first** ([SKILL.md](../SKILL.md#choose-the-pace)). For a business-critical
service use **two phases**: in Step 2, copy the old role's permissions instead of writing a narrow
policy; run Steps 3–7; observe for a full schedule cycle; then come back to Step 2 and narrow, with
[denial alarms](../templates/denial-alarm.tf) already wired.

## Step 0 — Ask, then look up

**Ask the user first**, in one message — the questions and a ready-made opening are in
[ask-the-user.md](../reference/ask-the-user.md). For ECS the answers that change the most:

- **Where is the app's code?** → scan it in Step 1 before touching CloudTrail.
- **How critical is it / what runs on a schedule?** → one step or two phases, and how long to observe.
- **How does it deploy, and where does its `.env` come from?** → where the role binding and the key live.

Skip anything already written in the repo (`CLAUDE.md`, CI workflow, Terraform). Then collect the
rest yourself — none of this needs the user:

| Needed | How |
|---|---|
| AWS account id, region, CLI profile | repo `CLAUDE.md`, or ask once if absent |
| Cluster / service | `aws ecs list-services --cluster <CLUSTER>` |
| Current task role and its policies | `describe-task-definition`, `list-attached-role-policies` |
| Role path prefix and naming | [conventions.md](../reference/conventions.md) or the repo's own standard |

Then find **who owns the task definition** — this decides where the change goes:

```bash
aws ecs describe-services --cluster <CLUSTER> --services <SERVICE> \
  --query 'services[0].taskDefinition' --output text
aws ecs describe-task-definition --task-definition <ARN> \
  --query '[taskDefinition.registeredBy,taskDefinition.taskRoleArn]' --output text
```

- `registeredBy` is a CI user → edit the task-definition JSON **in the app repo** (often `.ecs/<env>/task-definition.json`).
  Console or CLI edits are erased by the next deploy.
- Managed by Terraform/CDK → edit that code.

## Step 1 — Find what the service actually calls

Never guess the policy. In this order:

1. **The code, if the user gave you access.** SDK clients, framework integrations (storage disks,
   queue and mail drivers), config keys, and schedules. This finds rare paths that measurement
   cannot. See [measuring-usage.md §5](../reference/measuring-usage.md#5-read-the-code).
2. **CloudTrail, split per task.** An ECS task role session is named after the task ID, so calls
   can be attributed to one service even while many share a role — use it to confirm the code
   reading and catch anything the code hides (dynamic client creation, libraries).
3. **Config values** for the real resource names (bucket, table, queue), from wherever the
   environment comes from.
4. **[hidden-dependencies.md](../reference/hidden-dependencies.md)** for what neither shows.

Report which items came from code, which from CloudTrail, and which the user confirmed.

## Step 2 — Create the role and its policy (attached to nothing yet → zero risk)

**Two-phase (critical services)** — copy the permissions the workload has today, unchanged:

```bash
aws iam list-attached-role-policies --role-name <OLD_ROLE> --query 'AttachedPolicies[].PolicyArn'
aws iam list-role-policies --role-name <OLD_ROLE>       # then get-role-policy for each
```

Attach the same managed policies and inline documents to the new role. Nothing can break for lack
of permission. Narrowing happens later, from evidence — skip ahead to Step 3.

**One step (small services)** — write the narrow policy now:

Start from [terraform-role.tf](../templates/terraform-role.tf) — role and trust only — then add
statements from [policy-snippets.md](../templates/policy-snippets.md), **one per service the
measurement actually showed**. If the service calls nothing, it needs no policy at all: a role with
an empty policy is a valid and common outcome. Non-negotiables:

- Trust policy restricted to `ecs-tasks.amazonaws.com` **with `aws:SourceAccount` and `aws:SourceArn`**
  (prevents the confused-deputy problem).
- No `*FullAccess` managed policies. No default `Resource: "*"`.
- Actions from the code, resource ARNs from config/measurement. Never paste a snippet "just in case".
- Start narrow. Denials are visible and cheap to fix; over-permission is invisible.

Verify with the simulator before going near the service — assert **both** what must be allowed and
what must be denied:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::<ACCOUNT>:role<PATH><ROLE> \
  --action-names s3:PutObject --resource-arns 'arn:aws:s3:::<BUCKET>/x' \
  --query 'EvaluationResults[0].EvalDecision' --output text
```

## Step 3 — Attach the role and deploy (behaviour does not change yet)

Add one line next to `executionRoleArn`:

```json
"taskRoleArn": "arn:aws:iam::<ACCOUNT>:role<PATH><ROLE>",
```

The static key still wins at this point, so nothing changes functionally. That is the point: this
deploy proves the role attaches and the task starts. **Wait for it to finish before Step 5.**

## Step 4 — Stop the app from passing credentials

The SDK finds credentials by itself:

    environment variables → ~/.aws profile → ECS task role → EC2 instance profile

If your code passes `credentials` explicitly, that wins. So don't pass them.

```python
boto3.client("s3", region_name=REGION)                      # no keys → default chain
```
```php
new S3Client(['version' => 'latest', 'region' => $region]); // no 'credentials' key
```

**Do not add "use the key if present, otherwise the role" branching.** A branch is a way back:
someone re-adds a key later and the role silently stops being used. Delete the credential plumbing
from config files too — not because it errors (most frameworks skip empty values) but because it is
a loaded gun.

## Step 5 — Remove the keys from the environment and redeploy

Only after Step 3's deploy is live.

```bash
# where the app's .env comes from (SSM Parameter Store is common)
aws ssm get-parameter --with-decryption --name <PARAM> --query Parameter.Value --output text \
  | grep -nE '^[[:space:]]*[A-Z_]*(ACCESS_KEY_ID|SECRET_ACCESS_KEY|_KEY|_SECRET)='
```

Delete or comment those lines. **Keep** region, bucket, queue and table settings — they are
configuration, not credentials. Then redeploy: if the `.env` is baked into the image at build time,
a restart is not enough.

## Step 6 — Verify

Drop in a diagnostics endpoint and the answer is one screen:
[FastAPI](../templates/diagnostics-fastapi.py) · [Laravel](../templates/diagnostics-laravel.php).
It reports *who am I calling as* plus a pass/fail per service. Add it **before** the migration and
you get a clean before/after (`user/…` → `assumed-role/…`).

Without one, use CloudTrail:

```bash
# calls now made by the new role
aws cloudtrail lookup-events --region <REGION> \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=<ROLE_ARN> \
  --start-time <DEPLOY_TIME> --query 'length(Events)' --output text

# the old key should go quiet
aws iam get-access-key-last-used --access-key-id <AKIA…> \
  --query 'AccessKeyLastUsed.[LastUsedDate,ServiceName]' --output text
```

Also grep the application logs for `AccessDenied`, `InvalidClientTokenId`, `CredentialsError`.
A denial message names the exact action and resource — add precisely that, nothing more.

**Deploy day is not the end of verification.** Queue workers and scheduled jobs usually share the
container but run on their own clock. List them
([hidden-dependencies.md §4](../reference/hidden-dependencies.md#4-scheduled-jobs-and-background-workers-))
and confirm each one has run successfully under the new role — a daily job means checking tomorrow,
a monthly one means next month. Keep the [denial alarms](../templates/denial-alarm.tf) on until then.

## Step 7 — Roll back, or finish

**Roll back**: restore the previous parameter version and redeploy (~20 min). The task-definition
change rides along with the same deploy.

**Finish**: after the old key has been idle for **at least one full cycle of the longest scheduled
job**, deactivate it (reversible), then delete it. Back up role/key metadata as JSON first. Record
what changed and how to undo it.

**Two-phase, phase 2**: once that cycle has passed, draft the narrow policy from evidence
([measuring-usage.md §3](../reference/measuring-usage.md#3-let-iam-access-analyzer-draft-the-policy)),
reconcile it with [hidden-dependencies.md](../reference/hidden-dependencies.md), apply it with alarms
on, and watch another cycle.

## Applying this at scale

One service at a time. A shared role used by many services cannot be narrowed safely until each
service has its own — so split first (copying the same permissions is fine, risk is zero), let
CloudTrail and Access Advisor accumulate per-role data, then tighten a month later.
