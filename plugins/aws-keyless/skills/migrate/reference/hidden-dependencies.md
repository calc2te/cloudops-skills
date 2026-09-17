# Hidden dependencies — what code review and CloudTrail will not show you

Measurement ([measuring-usage.md](measuring-usage.md)) finds the actions a workload performs.
It does **not** find everything that decides whether those actions succeed under a new identity.
The items below broke, or nearly broke, real migrations. None of them appear in application code.

Run this checklist **before narrowing permissions** on anything that matters. Each item has a
command; most take seconds.

---

## 1. SES identities with a default configuration set 🔴

An SES identity (domain or address) can carry a **default configuration set**. SES attaches it to
every send automatically — and authorises `ses:SendRawEmail` / `ses:SendEmail` against the
configuration-set ARN **as well as** the identity ARN.

The code never mentions it. A policy scoped to `identity/<domain>` alone fails with:

```
not authorized to perform 'ses:SendRawEmail' on resource '…:configuration-set/<name>'
```

```bash
aws sesv2 list-email-identities --query 'EmailIdentities[].IdentityName' --output text \
  | tr '\t' '\n' | while read id; do
    printf '%-40s %s\n' "$id" \
      "$(aws sesv2 get-email-identity --email-identity "$id" --query ConfigurationSetName --output text)"
  done
```

Anything other than `None` → add `arn:aws:ses:<REGION>:<ACCOUNT>:configuration-set/<name>` to the
send statement. See [policy-snippets.md](../templates/policy-snippets.md#ses).

*Seen in practice: a daily newsletter failed for every subscriber the morning after migration.*

## 2. Resource-based policies that name the old principal 🔴

If a bucket, key, queue or secret has a policy that allows the **old IAM user by ARN**, your new
role is not in it — and an explicit resource-policy grant is often the only thing letting the call
through. Worse, some of these policies *deny* everything except a named principal.

```bash
OLD='arn:aws:iam::<ACCOUNT>:user/<OLD_USER>'

# S3 bucket policies
for b in $(aws s3api list-buckets --query 'Buckets[].Name' --output text); do
  aws s3api get-bucket-policy --bucket "$b" --query Policy --output text 2>/dev/null \
    | grep -q "$OLD" && echo "s3: $b"
done

# KMS key policies
for k in $(aws kms list-keys --query 'Keys[].KeyId' --output text); do
  aws kms get-key-policy --key-id "$k" --policy-name default --query Policy --output text 2>/dev/null \
    | grep -q "$OLD" && echo "kms: $k"
done

# SQS / SNS / Secrets Manager / ECR / Lambda resource policies — same idea:
#   aws sqs get-queue-attributes --attribute-names Policy
#   aws sns get-topic-attributes --query Attributes.Policy
#   aws secretsmanager get-resource-policy
#   aws ecr get-repository-policy
#   aws lambda get-policy
```

Also search for `aws:username`, `aws:PrincipalArn` and `aws:userid` conditions — they pin access to
an identity just as effectively as a `Principal` block.

## 3. Encryption keys

- **SSE-KMS buckets** with a customer-managed key need `kms:Decrypt` / `GenerateDataKey` on that key.
  SSE-S3 (`AES256`) and AWS-managed keys need nothing.
- **DynamoDB, SQS, SNS, Secrets Manager** with a customer-managed key: same.
- The key policy must also allow the account (or the role) — see §2.

```bash
aws s3api get-bucket-encryption --bucket <BUCKET> \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault' --output json
```

## 4. Scheduled jobs and background workers 🔴

The request path is what you test after a deploy. It is rarely the only path.

- Cron schedules (`routes/console.php`, `crontab`, EventBridge rules, Celery beat, `node-cron`)
- Queue workers running in the same container under `supervisord` or similar
- Monthly jobs: billing, settlement, reports — a one-week observation window misses them entirely

```bash
# Laravel
grep -n "Schedule::\|->daily\|->weekly\|->monthly\|->cron(" routes/console.php app/Console/Kernel.php
# container process managers
grep -rn "command=" .docker/*/supervisord.conf 2>/dev/null
```

**The observation window must cover the longest schedule.** If something runs monthly, observe for
a month before narrowing.

## 5. Presigned URLs outlive nothing

A presigned URL signed with **temporary** credentials stops working when those credentials expire —
regardless of the expiry you asked for. IAM user keys could sign URLs valid for 7 days; role
sessions cannot.

```bash
grep -rn "temporaryUrl\|generate_presigned_url\|getSignedUrl\|createPresignedRequest" --include='*.{php,py,js,ts}' .
```

Anything above roughly an hour — especially links embedded in **emails** or stored in a database —
needs a different design (CloudFront signed URLs, or re-signing on access).

## 6. ECS Exec and other platform features

Features that used to work because the old shared role was broad:

- **ECS Exec** (`enableExecuteCommand: true`) needs four `ssmmessages:*` actions on the task role.
- **X-Ray / OpenTelemetry exporters** need `xray:PutTraceSegments` etc.
- **CloudWatch agent / custom metrics** need `cloudwatch:PutMetricData`.

```bash
aws ecs describe-services --cluster <CLUSTER> --services <SERVICE> \
  --query 'services[0].enableExecuteCommand'
```

## 7. Data-plane calls that CloudTrail does not record

Not in CloudTrail by default: S3 object operations, DynamoDB item operations, SQS message traffic,
**SES sending**, Kinesis records. "Zero events" for these proves nothing. Cover them from config and
code instead, and prefer to observe them through application logs after the switch.

## 8. Network-scoped conditions

Resource policies with `aws:SourceIp` or `aws:SourceVpce` conditions care about where the call comes
from, not who makes it. Usually unaffected by the identity switch — but check them if the migration
also moves the workload (new subnets, new NAT, VPC endpoints).

---

## When to run this

| workload | before switching identity | before narrowing permissions |
|---|---|---|
| small, well-understood | §1 §2 §6 | full list |
| business-critical | §1 §2 §3 §6 | full list + observation covering §4 |

Two-phase migration for critical workloads is described in
[SKILL.md](../SKILL.md#choose-the-pace).
