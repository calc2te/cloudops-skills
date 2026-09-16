# Policy snippets — pick only what the workload actually uses

A menu, not a starter pack. Most workloads need one or two of these. If measurement
([measuring-usage.md](../reference/measuring-usage.md)) showed no calls to a service, it does not
belong in the policy — and a workload that calls nothing needs no policy at all.

Each entry lists the **minimum actions** for a common usage pattern and the **resource ARN shape**.
Widen only from a real `AccessDenied`, never in anticipation.

Format is JSON statements (drop into `jsonencode({...})` in Terraform, or a policy document).

---

## S3

Read only:
```json
{ "Sid": "S3Read", "Effect": "Allow",
  "Action": ["s3:GetObject"],
  "Resource": "arn:aws:s3:::<BUCKET>/<PREFIX>/*" }
```

Read + write (uploads use multipart above ~8 MB, hence the abort action):
```json
{ "Sid": "S3ReadWrite", "Effect": "Allow",
  "Action": ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"],
  "Resource": "arn:aws:s3:::<BUCKET>/<PREFIX>/*" }
```

Listing — note this one targets the **bucket** ARN, without `/*`:
```json
{ "Sid": "S3List", "Effect": "Allow",
  "Action": ["s3:ListBucket"],
  "Resource": "arn:aws:s3:::<BUCKET>",
  "Condition": { "StringLike": { "s3:prefix": ["<PREFIX>/*"] } } }
```

Notes
- Scope to a **prefix** when you can; whole-bucket access is rarely needed.
- `exists()` / `headObject` / `mimeType` need `s3:GetObject`, not a separate action.
- A "move" is copy + delete: `GetObject` + `PutObject` + `DeleteObject`.
- Presigned URLs need no extra permission to *create*; the signer's `GetObject` is what is used.
- SSE-KMS buckets additionally need the KMS snippet below.

## DynamoDB

Read:
```json
{ "Sid": "DdbRead", "Effect": "Allow",
  "Action": ["dynamodb:GetItem", "dynamodb:Query"],
  "Resource": "arn:aws:dynamodb:<REGION>:<ACCOUNT>:table/<TABLE>" }
```

Read + write:
```json
{ "Sid": "DdbWrite", "Effect": "Allow",
  "Action": ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:PutItem",
             "dynamodb:UpdateItem", "dynamodb:BatchWriteItem"],
  "Resource": "arn:aws:dynamodb:<REGION>:<ACCOUNT>:table/<TABLE>" }
```

Notes
- Add `dynamodb:Scan` only if the code really scans — it is the expensive, easily-abused one.
- Indexes are separate resources: `…:table/<TABLE>/index/*`.
- AWS-managed encryption (`alias/aws/dynamodb`) needs no KMS permission; a customer-managed key does.
- `DescribeTable` is needed by SDK helpers that inspect the key schema (e.g. some ORMs).

## SQS

Consumer (queue worker):
```json
{ "Sid": "SqsConsume", "Effect": "Allow",
  "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage",
             "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"],
  "Resource": "arn:aws:sqs:<REGION>:<ACCOUNT>:<QUEUE>" }
```

Producer:
```json
{ "Sid": "SqsSend", "Effect": "Allow",
  "Action": ["sqs:SendMessage", "sqs:GetQueueAttributes"],
  "Resource": "arn:aws:sqs:<REGION>:<ACCOUNT>:<QUEUE>" }
```

Notes
- Add `sqs:GetQueueUrl` only if the code resolves the URL by name instead of configuring it.
- Dead-letter queues are a separate ARN — grant `SendMessage` on the DLQ to the *queue*, not the app.

## SES

```json
{ "Sid": "SesSend", "Effect": "Allow",
  "Action": ["ses:SendRawEmail", "ses:SendEmail"],
  "Resource": "arn:aws:ses:<REGION>:<ACCOUNT>:identity/<DOMAIN_OR_ADDRESS>" }
```

Notes
- Scope to the verified identity so a compromised app cannot send as your other domains.
- SES v1 transports (older framework mailers) call `SendRawEmail`; v2 clients call `SendEmail`.
  Grant the one your library uses; both is acceptable while you find out.
- Tighten further with `"Condition": {"StringEquals": {"ses:FromAddress": "<ADDRESS>"}}`.

## Secrets Manager / SSM Parameter Store

```json
{ "Sid": "ReadSecrets", "Effect": "Allow",
  "Action": ["secretsmanager:GetSecretValue"],
  "Resource": "arn:aws:secretsmanager:<REGION>:<ACCOUNT>:secret:<NAME>-??????" }
```
```json
{ "Sid": "ReadParams", "Effect": "Allow",
  "Action": ["ssm:GetParameter", "ssm:GetParameters"],
  "Resource": "arn:aws:ssm:<REGION>:<ACCOUNT>:parameter/<PATH>/*" }
```

Notes
- Secrets Manager ARNs end in a random 6-character suffix — `-??????` matches it without
  pinning the exact secret version ARN.
- 🔴 `SecretsManagerReadWrite` and `AmazonSSMFullAccess` are how one compromised app becomes an
  account-wide breach. Never attach them to a workload role.
- If the platform injects secrets for you (ECS `secrets:`, Lambda env from SSM), the **execution**
  role needs this, not the task role.

## Bedrock

```json
{ "Sid": "BedrockInvoke", "Effect": "Allow",
  "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
  "Resource": ["arn:aws:bedrock:<REGION>:<ACCOUNT>:inference-profile/*",
               "arn:aws:bedrock:*::foundation-model/<VENDOR>.*"] }
```

Notes
- `Converse` → `InvokeModel`; `ConverseStream` → `InvokeModelWithResponseStream`. There is no
  `bedrock:Converse` action.
- Cross-region inference profiles (`global.*`, `us.*`) fan out to several regions, so the
  foundation-model ARN needs the region wildcard (it also matches the region-less form).
- Knowledge bases: `{"Action": "bedrock:Retrieve", "Resource": "arn:aws:bedrock:<REGION>:<ACCOUNT>:knowledge-base/<KB_ID>"}`.
- Limit `<VENDOR>` (e.g. `anthropic.`) rather than allowing every model in the catalogue.

## KMS (only for customer-managed keys)

```json
{ "Sid": "KmsViaService", "Effect": "Allow",
  "Action": ["kms:Decrypt", "kms:GenerateDataKey"],
  "Resource": "arn:aws:kms:<REGION>:<ACCOUNT>:key/<KEY_ID>",
  "Condition": { "StringEquals": { "kms:ViaService": "s3.<REGION>.amazonaws.com" } } }
```

The `ViaService` condition means the key can only be used through that service — a stolen role
cannot decrypt the data directly.

## ECS Exec (debug shell into a task)

```json
{ "Sid": "EcsExec", "Effect": "Allow",
  "Action": ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
             "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"],
  "Resource": "*" }
```

One of the few honest `Resource: "*"` cases — these actions have no resource-level permissions.
Comment it so a future reader knows it is deliberate. Grant only to services where
`enableExecuteCommand` is actually on.

## CloudWatch (dashboards, custom metrics)

```json
{ "Sid": "PutMetrics", "Effect": "Allow",
  "Action": ["cloudwatch:PutMetricData"],
  "Resource": "*",
  "Condition": { "StringEquals": { "cloudwatch:namespace": "<NAMESPACE>" } } }
```

`PutMetricData` has no resource-level permission either; the namespace condition is the scope.
For read-only dashboard queries, `CloudWatchReadOnlyAccess` is acceptable — it is genuinely read-only.

---

## Before you paste

1. Did measurement show this service? If not, leave it out.
2. Is every `<PLACEHOLDER>` replaced with a real name — no wildcards you did not think about?
3. Any `Resource: "*"` left? Each one needs a comment explaining why it cannot be scoped.
4. Simulate both directions:

```bash
aws iam simulate-principal-policy --policy-source-arn <ROLE_ARN> \
  --action-names <ACTION> --resource-arns <ARN> \
  --query 'EvaluationResults[0].EvalDecision' --output text     # expect: allowed
# then assert a neighbouring resource is denied (other environment's table, another bucket)
```
