# ECS: static keys → per-service task role

Run end to end on production services. **The order is the whole trick** — reverse it and you ship a
container with neither a key nor a role, and the service dies.

Prerequisites: [conventions](../reference/conventions.md) for naming and policy rules,
[pitfalls](../reference/pitfalls.md) open beside you — every item there is a silent failure.

## Step 0 — Collect the context you need

Ask the user, or read it from the repo (`CLAUDE.md`, terraform, CI workflow) if it is written down:

| Needed | Example | Why |
|---|---|---|
| AWS account id, region | `123456789012`, `ap-northeast-2` | every ARN |
| CLI profile | `--profile acme-prod` | all commands below |
| Cluster / service | `myapp-stage` / `api` | the target |
| Role path prefix | `/acme/` (optional) | separates human-made roles from auto-generated ones |
| Naming convention | `ecs-<task-def>-<env>` | see conventions.md |

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

## Step 1 — Measure what the service actually calls

Never guess the policy. See [measuring-usage.md](../reference/measuring-usage.md).

The key technique: **an ECS task role session is named after the task ID**, so CloudTrail can be
split per service even while many services share one role. Combine that with the app's config
(bucket / table / queue names) and a grep for SDK clients in the code.

## Step 2 — Create the role and a narrow policy (attached to nothing yet → zero risk)

Start from [terraform-role.tf](../templates/terraform-role.tf). Non-negotiables:

- Trust policy restricted to `ecs-tasks.amazonaws.com` **with `aws:SourceAccount` and `aws:SourceArn`**
  (prevents the confused-deputy problem).
- No `*FullAccess` managed policies. No default `Resource: "*"`.
- Actions from the code, resource ARNs from config/measurement.
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

## Step 7 — Roll back, or finish

**Roll back**: restore the previous parameter version and redeploy (~20 min). The task-definition
change rides along with the same deploy.

**Finish**: after the old key has been idle for at least a day, deactivate it (reversible), then
delete it. Back up role/key metadata as JSON first. Record what changed and how to undo it.

## Applying this at scale

One service at a time. A shared role used by many services cannot be narrowed safely until each
service has its own — so split first (copying the same permissions is fine, risk is zero), let
CloudTrail and Access Advisor accumulate per-role data, then tighten a month later.
