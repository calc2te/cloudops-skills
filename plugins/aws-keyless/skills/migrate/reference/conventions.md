# Role conventions and policy design

Nothing here is AWS-mandated — it is a set of defaults that survived contact with a messy account
(349 roles, five naming styles, one shared role used by 15 services). Adapt the names, keep the
reasoning.

## Separate what you made from what AWS made

Most roles in an old account were not created deliberately: `/service-role/` from consoles,
`AWSServiceRoleFor*`, CloudFormation/CDK/Amplify artifacts with random suffixes. You cannot govern
what you cannot list.

Use an **IAM path** rather than a name prefix:

    arn:aws:iam::<ACCOUNT>:role/<org>/ecs-api-prod
                                 └ ours   └ what it is

| | name prefix (`acme-…`) | **IAM path** (`/acme/`) |
|---|---|---|
| list them | string matching | `aws iam list-roles --path-prefix /acme/` — supported by the API |
| use in policy | no | `Resource: arn:…:role/acme/*` — permission boundaries, `iam:PassRole` limits |
| multiple products | prefix becomes noise (`acme-ecs-productb-api`) | path = ownership, name = target |

Path and name are **immutable after creation**. Apply to new roles; migrate old ones when you
happen to touch them.

## Name: what kind of identity, then whose

    <identity-kind>-<source or workload>-<environment>       lowercase kebab-case

| prefix | identity | trusted by |
|---|---|---|
| `sso-` | a human, via an external IdP | SAML / OIDC provider |
| `oidc-` | an external machine (CI, a PaaS) | OIDC provider |
| `ecs-` | ECS **task** role — the app calling AWS | `ecs-tasks.amazonaws.com` |
| `ecsexec-` | ECS **execution** role — image pull, logs | `ecs-tasks.amazonaws.com` |
| `ec2-` `lambda-` `svc-` | instance profiles, functions, service-to-service | the service |

Why split humans off first: in a large account human roles are a tiny minority and there is no way
to find them. `sso-*` answers "every permission granted to a person" in one query — which is what
an access review asks for.

Use the **task definition family** in the middle segment, not the service name: service names
collide across clusters (four clusters can each have a `traefik`).

Keep `Project`/`Team` out of the name. Tags are the single source of truth for classification;
names that encode ownership go stale when teams reorganise.

## Always write the environment suffix

`-prod` · `-stage` · `-qa` · `-dev`. Even if the rest of your infrastructure follows the common
"no suffix means prod" convention.

IAM is the exception because **the name is the permission boundary**. A stage role denies the prod
table; a prod role allows it. Pick the wrong cluster name and your deploy fails loudly — pick the
wrong role name and it **succeeds quietly** against the wrong data.

It also matters for automation: an implicit convention is something a human remembers and a tool
has to infer. Inference becomes a wrong guess.

If your tag values are long (`production`, `staging`) and your resource names are short
(`prod`, `stage`), write the mapping down somewhere. Both are fine; drifting between them is not.

## Tags

`Project` · `Service` · `Team` · `Environment` · `ManagedBy` — roles are not billed, but
"whose is this?" gets asked during offboarding, access review and incidents.

If your Terraform provider sets `ignore_tags` for some keys, do not also list those keys in the
resource's `tags{}` block: the provider stops ignoring them and your standard values get
overwritten by whatever the code says.

## Policy rules

1. **One role per workload.** A shared role means one compromised app exposes everything, CloudTrail
   cannot attribute actions, and no single service can be tightened.
2. **No `*FullAccess`.** Also check policies whose names sound narrow but are not — e.g. AWS's
   `AmazonBedrockLimitedAccess` includes inference-profile creation and marketplace subscription.
3. **No default `Resource: "*"`.** Scope to your bucket/table/queue. Exceptions exist (some actions
   have no resource-level permissions, e.g. `ssmmessages:*` for ECS Exec) — comment them.
4. **Start narrow, widen on evidence.** A denial tells you the exact action and resource.
5. **Never mix execution role and task role.** Image pull and logging are the platform's job.

## Trust policy for ECS task roles

```json
{
  "Effect": "Allow",
  "Principal": { "Service": "ecs-tasks.amazonaws.com" },
  "Action": "sts:AssumeRole",
  "Condition": {
    "StringEquals": { "aws:SourceAccount": "<ACCOUNT>" },
    "ArnLike": { "aws:SourceArn": "arn:aws:ecs:<REGION>:<ACCOUNT>:*" }
  }
}
```

## Action mapping people get wrong

| what the app does | IAM action |
|---|---|
| Bedrock `Converse` | `bedrock:InvokeModel` |
| Bedrock `ConverseStream` | `bedrock:InvokeModelWithResponseStream` |
| Knowledge base lookup | `bedrock:Retrieve` on the KB ARN |
| S3 `exists` / download / presigned GET | `s3:GetObject` |
| S3 upload (multipart) | `s3:PutObject` + `s3:AbortMultipartUpload` |
| S3 listing | `s3:ListBucket` on the **bucket** ARN (no `/*`) |
| S3 move | `s3:GetObject` + `s3:PutObject` + `s3:DeleteObject` |
| Laravel queue worker (SQS) | `ReceiveMessage`, `DeleteMessage`, `SendMessage`, `GetQueueAttributes`, `ChangeMessageVisibility` |
| Laravel mail (SES v1 transport) | `ses:SendRawEmail`, scoped to the identity ARN |
| ECS Exec | four `ssmmessages:*` actions, `Resource: "*"` unavoidable |

**Cross-region inference profiles** (`global.*`, `us.*`) route requests to several regions, so the
foundation-model resource needs a region wildcard — `arn:aws:bedrock:*::foundation-model/<vendor>.*`
also matches the region-less form.

**DynamoDB encryption**: with the AWS-managed key (`alias/aws/dynamodb`) no KMS permission is
needed. With a customer-managed key, add `kms:Decrypt`/`GenerateDataKey` with a `kms:ViaService`
condition.
