# Measuring what a service actually calls

The policy is `actions the code performs` × `resource names from config and measurement`.
Guessing produces either an outage or a policy nobody can defend. All commands below take your
usual `--profile` / `--region`.

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

## 2. Look from the key's side

```bash
# is this key still alive, and what did it last touch?
aws iam get-access-key-last-used --access-key-id <AKIA…> \
  --query 'AccessKeyLastUsed.[LastUsedDate,ServiceName,Region]' --output text

# which services has this principal used (Access Advisor, ~400 day window)
JOB=$(aws iam generate-service-last-accessed-details --arn arn:aws:iam::<ACCOUNT>:user/<USER> \
        --granularity ACTION_LEVEL --query JobId --output text)
aws iam get-service-last-accessed-details --job-id "$JOB" \
  --query 'ServicesLastAccessed[?LastAuthenticated].[ServiceNamespace,LastAuthenticated]' --output text

# the actual calls, with model / table / bucket where present
aws cloudtrail lookup-events --region <REGION> \
  --lookup-attributes AttributeKey=Username,AttributeValue=<IAM_USER> \
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

**When one key is shared by prod and stage**, IP and user-agent usually cannot separate them.
Migrate one environment first — the remaining traffic is then, by definition, the other one.
Measure again at that point and the picture is clean.

## 3. What CloudTrail will not show you

Data-plane operations are not logged by default: S3 object reads/writes, DynamoDB item operations,
SQS message traffic. Work around it:

- **Indirect evidence**: if a DynamoDB table is KMS-encrypted, the `Decrypt` event carries
  `encryptionContext["aws:dynamodb:tableName"]`. S3 sometimes leaves `GetBucketLocation`.
- **Config is authoritative** for names: buckets, tables, queues and regions are in the app's
  settings, not in CloudTrail.

## 4. Read the code

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

## 5. Check which code paths are actually reachable

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
