# Measuring what a service actually calls

The policy is `actions the code performs` × `resource names from config and measurement`.
Guessing produces either an outage or a policy nobody can defend. All commands below take your
usual `--profile` / `--region`.

**Source priority**: ask for the code first ([ask-the-user.md](ask-the-user.md)). If you have it,
§5 is your primary source and the CloudTrail sections below are the cross-check. If you do not,
CloudTrail is all you have — say so in the result, because rare paths (monthly jobs, admin-only
features) will be missing.

## 1. Split CloudTrail per service (works even with a shared role)

An ECS task role session is named after the **task ID**. So even when twenty services share one
role, you can attribute calls precisely.

```bash
# task IDs for this service
aws ecs list-tasks --cluster <CLUSTER> --service-name <SERVICE> --query 'taskArns' --output text \
  | tr '\t' '\n' | sed 's|.*/||'

# what that task called — query each region you suspect, CloudTrail is regional
aws cloudtrail lookup-events --region <REGION> \
  --lookup-attributes AttributeKey=Username,AttributeValue=<TASK_ID> \
  --max-items 1000 --output json \
  | python3 -c "
import json,sys,collections
c=collections.Counter()
for e in json.load(sys.stdin)['Events']:
    d=json.loads(e['CloudTrailEvent'])
    arn=d['userIdentity'].get('arn','')
    role=arn.split('/')[1] if 'assumed-role' in arn else arn
    c[(role, d['eventSource'].split('.')[0], d['eventName'], d.get('errorCode','OK'))]+=1
for k,v in c.most_common(20): print(v,*k)"
```

Reading the result:

- Events under the **execution** role (ECR pulls, `CreateLogStream`) are the platform's, not the
  app's. If those are the *only* events, the app is not using its task role.
- An app that clearly calls AWS but shows no task-role events is authenticating some other way —
  usually a static key baked into the image.

## 2. Inspect the key being replaced — its permissions are what the app runs with today

If the application authenticates with a static key, **the permissions in effect are that key's
IAM user's**, not the task/instance role attached to the workload. The SDK uses the key first
([pitfalls §2](pitfalls.md#2-environment-variables-beat-the-task-role-)); the attached role sits
unused. So when you "keep today's permissions", this is the set to keep — and when you narrow, this
is the ceiling to narrow from.

Inventory **every** key the app reads, not just `AWS_ACCESS_KEY_ID`. Apps often carry a second
pair for one service (`DYNAMODB_KEY`, `S3_KEY`, `SES_KEY`…).

### 2a. Which user owns each key — and does the key still exist?

Only the access key **ID** is needed (never print the secret):

```bash
aws ssm get-parameter --with-decryption --name <PARAM> --query Parameter.Value --output text   | grep -E '^[A-Z_]*(ACCESS_KEY_ID|_KEY)=(AKIA|ASIA)' | sed -E 's/=(.{4}).{12}(.{4})/=\1…\2/'

aws iam get-access-key-last-used --access-key-id <AKIA…>   --query '[UserName,AccessKeyLastUsed.LastUsedDate,AccessKeyLastUsed.ServiceName]' --output text
```

- Returns a user → continue below.
- **`NoSuchEntity` / `AccessDenied` for a key in your own account** → the key was deleted or belongs
  to another account. Every call the app makes with it is **failing today**. Do not "preserve" that
  behaviour; find the feature, tell the user, and decide what it *should* have access to.
- `LastUsedDate` empty or months old → the path using it may be dead code, or rare. Ask.

### 2b. What that user is allowed to do

Permissions come from four places; check all of them.

```bash
U=<USER>
aws iam list-attached-user-policies --user-name $U --query 'AttachedPolicies[].PolicyArn' --output text
aws iam list-user-policies          --user-name $U --query 'PolicyNames' --output text   # then get-user-policy
aws iam list-groups-for-user        --user-name $U --query 'Groups[].GroupName' --output text
#   for each group: list-attached-group-policies, list-group-policies / get-group-policy
aws iam get-user --user-name $U --query 'User.PermissionsBoundary' --output text          # caps everything above
```

Read the result for:

- **`*FullAccess` or `AdministratorAccess`** — common on old app keys. Copying it to a role is not a
  "safe phase 1"; it is moving an over-privileged credential somewhere harder to see. Copy it only
  as a short-lived bridge, with narrowing already scheduled.
- **Permissions for services the code never calls** — leftovers from another project or a person.
- **Explicit `Deny` statements or a permissions boundary** — the key may be *less* capable than its
  allow list suggests; the new role must not silently become more capable.

### 2c. What that user actually used

```bash
# services and actions used (Access Advisor, ~400 day window; action-level for some services)
JOB=$(aws iam generate-service-last-accessed-details --arn arn:aws:iam::<ACCOUNT>:user/<USER> \
        --granularity ACTION_LEVEL --query JobId --output text)
aws iam get-service-last-accessed-details --job-id "$JOB" \
  --query 'ServicesLastAccessed[?LastAuthenticated].[ServiceNamespace,LastAuthenticated]' --output text

# the actual calls, with model / table / bucket where present
aws cloudtrail lookup-events --region <REGION> \
  --lookup-attributes AttributeKey=Username,AttributeValue=<USER> \
  --start-time <ISO8601> --max-items 3000 --output json | python3 -c "
import json,sys,collections
c=collections.Counter()
for e in json.load(sys.stdin)['Events']:
    d=json.loads(e['CloudTrailEvent']); rp=d.get('requestParameters') or {}
    ctx=rp.get('encryptionContext') or {}
    tgt=rp.get('modelId') or ctx.get('aws:dynamodb:tableName') or rp.get('bucketName') or ''
    c[(d['eventName'], str(tgt)[:60], d.get('errorCode','OK'))]+=1
for k,v in c.most_common(15): print(v,*k)"
```

**Granted (2b) minus used (2c) is the over-privilege** you are about to stop carrying. Record it —
it is the before/after number that shows the migration was worth doing.

### 2d. Is the key shared?

One key used by several workloads (or by prod **and** stage, or by a workload **and** a person)
means its usage is a union. IP and user-agent usually cannot separate them. Migrate one consumer
first — the remaining traffic is then, by definition, the others. Measure again at that point.

Do not delete or deactivate a shared key until **every** consumer has moved.

### Which permissions are "in effect today"?

| how the app authenticates | effective permissions to keep in phase 1 |
|---|---|
| static key only | the key user's (2b), **not** the attached role |
| role only (no key) | the attached role's |
| some clients pass a key, others do not | the **union** of the key user and the attached role |
| a key that no longer exists | none — that path is broken; decide deliberately |

## 3. Let IAM Access Analyzer draft the policy

After a role has run for a while (phase 1 of a two-phase migration), Access Analyzer can generate a
policy from that role's actual CloudTrail activity — up to 90 days.

```bash
aws accessanalyzer start-policy-generation   --policy-generation-details principalArn=<ROLE_ARN>   --cloud-trail-details '{"trails":[{"cloudTrailArn":"<TRAIL_ARN>","allRegions":true}],
      "accessRole":"<ROLE_ALLOWING_ANALYZER_TO_READ_TRAIL>",
      "startTime":"<ISO8601>","endTime":"<ISO8601>"}'   --query jobId --output text

aws accessanalyzer get-generated-policy --job-id <JOB_ID>   --query 'generatedPolicyResult.generatedPolicies[].policy' --output text
```

Treat the output as a **draft**: it only knows management events (see §4), it tends to use `*` for
resources you then have to fill in, and it cannot see schedules that did not run inside the window.
Reconcile it with [hidden-dependencies.md](hidden-dependencies.md) before applying.

## 4. What CloudTrail will not show you

Data-plane operations are not logged by default: S3 object reads/writes, DynamoDB item operations,
SQS message traffic, **SES sending**. Work around it:

- **Indirect evidence**: if a DynamoDB table is KMS-encrypted, the `Decrypt` event carries
  `encryptionContext["aws:dynamodb:tableName"]`. S3 sometimes leaves `GetBucketLocation`.
- **Config is authoritative** for names: buckets, tables, queues and regions are in the app's
  settings, not in CloudTrail.

## 5. Read the code

```bash
# Python
grep -rn "boto3.client(\|boto3.resource(" --include='*.py' . | grep -v -E "venv|site-packages"

# PHP / Laravel
grep -rn "new .*Client(" app
grep -rhoE "Storage::disk\('[a-z0-9-]+'\)" app | sort | uniq -c
grep -n "'key' => env(" config/*.php        # where the framework reads credentials

# Node
grep -rn "new \(S3\|DynamoDB\|SQS\|SES\)Client(" --include='*.ts' --include='*.js' src
```

Collect every bucket / table / queue / region from config, then resolve the real values from
whatever supplies the environment (SSM parameter, secret, CI variable) — printing **names only**:

```bash
aws ssm get-parameter --with-decryption --name <PARAM> --query Parameter.Value --output text \
  | grep -E '^[A-Z_]+=' | sed -E 's/=(.{4}).*/=\1…/'
```

## 6. Check which code paths are actually reachable

Routes that exist in code but have had no traffic for a month do not need permissions yet. If the
service fronts HTTP, the access log answers it:

```bash
aws logs start-query --log-group-name <LOG_GROUP> \
  --start-time $(( $(date +%s) - 30*86400 )) --end-time $(date +%s) \
  --query-string 'parse @message /"(?<method>[A-Z]+) (?<path>[^ ?]*)[^"]*" (?<code>\d+)/
    | filter ispresent(path) | stats count(*) as n by path, code | sort n desc | limit 20'
```

Leaving them out is safe in a way that guessing is not: the failure mode is a logged AccessDenied
naming exactly what to add.
