# Lambda: static keys → execution role

> Status: derived from the ECS playbook plus AWS docs — not yet run end to end by the authors.

Prerequisites: [conventions](../reference/conventions.md), [pitfalls](../reference/pitfalls.md).

Lambda always has an execution role — that is how it writes logs. So the migration is usually not
"attach a role" but "**stop the function from overriding it** with keys in its environment".

## Step 0 — Context

```bash
aws lambda get-function-configuration --function-name <FN> \
  --query '[Role,Runtime,Environment.Variables]' --output json
```

Look for `AWS_ACCESS_KEY_ID` or app-specific key variables in `Environment.Variables`.
Note who deploys the function: Serverless Framework, SAM, CDK, Terraform, or a console upload —
editing the console copy is pointless if a framework redeploys it.

⚠️ Lambda **reserves** the `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`
variable names for the execution role's own credentials. If someone set them explicitly, the
function is running as something other than its role — and the deployment tool may have been
rejecting or silently overwriting them. Treat their presence as the bug.

## Step 1 — Measure

Lambda sessions appear in CloudTrail as `assumed-role/<execution-role>/<function-name>`, so
attribution is free. Scope the search to the function's role and read the action list.
See [measuring-usage.md](../reference/measuring-usage.md).

Access Advisor on the execution role is unusually useful here: functions are small, so
"services never used in 400 days" is a reliable signal for trimming.

## Step 2 — Role and policy

Trust:

```json
{
  "Effect": "Allow",
  "Principal": { "Service": "lambda.amazonaws.com" },
  "Action": "sts:AssumeRole"
}
```

Attach `AWSLambdaBasicExecutionRole` (logs) **or** write the three `logs:*` actions yourself scoped
to the function's log group — the managed policy is small enough that either is defensible. Then
add only the measured actions, with real resource ARNs
([terraform-role.tf](../templates/terraform-role.tf) for the body).

Name it `lambda-<function>-<env>` per [conventions](../reference/conventions.md).

If the function is in a VPC it also needs `ec2:CreateNetworkInterface`,
`DescribeNetworkInterfaces`, `DeleteNetworkInterface` — use the managed
`AWSLambdaVPCAccessExecutionRole` rather than hand-rolling these.

## Step 3 — Point the function at the role

```bash
aws lambda update-function-configuration --function-name <FN> --role <ROLE_ARN>
```

Do the same in whatever actually owns the deployment, or the next deploy reverts it.

## Step 4 — Stop passing credentials

Same rule: no explicit credentials in the SDK client constructor. In Lambda the default chain reads
the execution role's credentials from the reserved environment variables, so an app that passes
nothing works everywhere.

## Step 5 — Remove the key variables

```bash
aws lambda update-function-configuration --function-name <FN> \
  --environment "Variables={<keep the non-credential ones>}"
```

This replaces the whole map — read the current variables first and put back everything except the
credentials. Also remove them from the source of truth (`serverless.yml`, `template.yaml`, CDK,
Terraform, or the CI secret that injects them).

## Step 6 — Verify

Invoke the function and check CloudWatch Logs for credential errors. A one-liner inside the
handler (temporarily) is the fastest proof:

```python
import boto3
print(boto3.client("sts").get_caller_identity()["Arn"])   # expect assumed-role/<role>/<fn>
```

## Step 7 — Roll back, or finish

Roll back by restoring the previous environment variables (keep a copy of the JSON before you
change it). Then let the old key sit idle for a day, deactivate, delete.

**While you are here**: functions deployed by Serverless/SAM often share one over-broad role
across a whole stack. Splitting per function is the same exercise as splitting a shared ECS role,
and the same two-stage approach applies — separate first, narrow later.
