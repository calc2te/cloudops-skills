# Security baseline — settings Security Hub will flag on day one

**Why this file exists.** In one account, a single new project created on one day produced 13 new
AWS Security Hub findings: a public Lambda URL, an ECR repository, a Terraform state bucket and a
secret, each missing the same handful of settings. None of them was hard to set; all of them are
hard to add later because something already depends on the old behaviour. Setting them at birth is
cheap, retrofitting is a migration.

Each rule names the Security Hub control (AWS Foundational Security Best Practices) it satisfies,
so a finding on the dashboard and a line in this file use the same ID.

> Status: every rule comes from findings seen in a real account. Rule 2 is in production use
> (ECS services built from these templates). Rules 1 and 3–6 are derived from the control
> definitions and AWS documentation and have **not** been rolled out across a fleet yet — read the
> "breaks" line before turning them on for an existing workload.

| # | rule | controls |
|---|---|---|
| 1 | Public Lambda function URL only for webhooks — verify, cap, label | Lambda.1 |
| 2 | ECS tasks get no public IP | ECS.2 · ECS.16 |
| 3 | Containers: read-only root filesystem, non-root user, logging | ECS.5 · ECS.20 · ECS.9 |
| 4 | ECR: immutable tags, lifecycle policy | ECR.2 · ECR.3 |
| 5 | S3 (Terraform state included): TLS only, access logging, lifecycle | S3.5 · S3.9 · S3.13 |
| 6 | Secrets: rotate, or write down why not | SecretsManager.1 · SecretsManager.4 |

---

## 1. Public Lambda function URL — only for webhooks, and then verify, cap and label

`authorization_type = "NONE"` makes the function callable by anyone who has the URL. Lambda.1
fails for it, and it **keeps failing** even when the URL is intended — the control cannot know.

Use `NONE` only when the caller cannot sign AWS requests (a SaaS webhook). Otherwise use
`AWS_IAM`, or put the function behind an API Gateway / ALB that does the authentication.

When `NONE` is right, all three of these are required:

- **Verify the sender in code** — the webhook's HMAC signature or shared secret, with a timestamp
  check against replay. Reject before doing any work (before calling a model, before enqueueing).
  Without this, the URL is an unauthenticated trigger for whatever the function does — including
  paid model calls.
- **Cap concurrency** — `reserved_concurrent_executions` on the function. A flood then costs at most
  N concurrent executions instead of scaling the bill.
- **Label it as intended** — tags `Exposure = "public"` and `ExposureReason = "<who calls it>"`.
  A reviewer, or a dashboard, can then separate "public by design" from "public by mistake"
  without opening the code.

```hcl
resource "aws_lambda_function" "receiver" {
  function_name                  = "${var.service_id}-receiver-${var.env}"
  reserved_concurrent_executions = 5
  # ...
  tags = {
    Service        = var.service_id
    Exposure       = "public"
    ExposureReason = "chat-tool webhook (HMAC verified in handler)"
  }
}

resource "aws_lambda_function_url" "receiver" {
  function_name      = aws_lambda_function.receiver.function_name
  authorization_type = "NONE"
}
```

Keep the function role as narrow as the webhook needs (read one secret, send to one queue). The
role is the blast radius if verification has a bug.

**Breaks:** a reserved concurrency that is too low throttles legitimate bursts (429 to the sender,
which usually retries). Start from observed peak, not from 1.

## 2. ECS tasks get no public IP

```hcl
network_configuration {
  subnets          = var.private_subnet_ids
  security_groups  = [aws_security_group.app.id]
  assign_public_ip = false
}
```

ECS.2 checks the service; ECS.16 checks **task sets**, which deployments create. With blue/green
deployments a new task set appears on every deploy, so one wrong setting shows up as a new finding
every day. If the service is right but task sets still fail, the deployment configuration carries
its own network block — for CodeDeploy, `AssignPublicIp` in the appspec's `AwsvpcConfiguration`.

**Breaks:** tasks in a subnet without a NAT gateway (or VPC endpoints for ECR, logs, secrets) lose
outbound access and fail to pull their image. Move them to private subnets with NAT first; a task
that needs a public IP to reach the internet is in the wrong subnet.

## 3. Containers: read-only root filesystem, non-root user, logging

In each container definition:

```hcl
container_definitions = jsonencode([{
  name                   = "app"
  readonlyRootFilesystem = true          # ECS.5
  user                   = "1000:1000"   # ECS.20 — any non-root UID; or the image's user, e.g. "www-data"
  logConfiguration = {                   # ECS.9
    logDriver = "awslogs"
    options = {
      awslogs-group         = "/ecs/${var.service_id}-${var.env}"
      awslogs-region        = var.region
      awslogs-stream-prefix = "app"
    }
  }
  mountPoints = [{ sourceVolume = "tmp", containerPath = "/tmp" }]
  # ...
}])

volume { name = "tmp" }   # task-scoped scratch space for the paths the app must write
```

Task definitions are immutable: every deploy registers a new revision, and Security Hub reports the
same problem again on the new revision. Fixing it in code once ends that.

**Breaks — test in a non-production environment first:**
- Read-only root: anything that writes outside mounted volumes fails — `/tmp`, framework caches
  (PHP sessions and compiled views, Node build caches), PID files, nginx temp paths. Mount a volume
  for each path the app writes; find them by running with the flag on in QA and reading the errors.
- Non-root: binding ports below 1024 and writing to root-owned directories fail. Listen on a high
  port (8080) and let the load balancer map it; check the image's documented non-root user.
- ECS.20 needs `user` set explicitly — an image that switches user inside its Dockerfile still fails
  the control. Setting the same user in the task definition costs nothing.

## 4. ECR: immutable tags, lifecycle policy

```hcl
resource "aws_ecr_repository" "app" {
  name                 = var.service_id
  image_tag_mutability = "IMMUTABLE"   # ECR.2
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "app" {   # ECR.3
  repository = aws_ecr_repository.app.name
  policy = jsonencode({ rules = [{
    rulePriority = 1
    description  = "keep last 50 images"
    selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 50 }
    action       = { type = "expire" }
  }] })
}
```

**Breaks:** pipelines that push `:latest` (or any reused tag) fail with `ImageTagAlreadyExistsException`.
Tag with the commit SHA and deploy by that tag or by digest — which is also what makes rollbacks
reproducible. Keep the lifecycle count above the number of images a rollback could need.

## 5. S3 — including the Terraform state bucket

A new project usually creates its state bucket by hand or with a bootstrap script, outside the
standards. It holds every secret Terraform has seen; treat it as the most sensitive bucket.

```hcl
data "aws_iam_policy_document" "tls_only" {   # S3.5
  statement {
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_logging" "this" {   # S3.9
  bucket        = aws_s3_bucket.this.id
  target_bucket = var.access_log_bucket
  target_prefix = "${aws_s3_bucket.this.id}/"
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {   # S3.13
  bucket = aws_s3_bucket.this.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 90 }
  }
}
```

For a state bucket also: versioning on, public access block on, and no `force_destroy`.

**Breaks:** the TLS-only policy is merged with any existing bucket policy — attach it through the
same `aws_s3_bucket_policy`, not a second one (the second overwrites the first). Access logs need a
separate target bucket; do not log a bucket into itself.

## 6. Secrets: rotate, or write down why not

SecretsManager.1 fails when rotation is not configured; SecretsManager.4 when the last rotation is
older than the window (90 days by default).

- **Database credentials** — use the managed rotation (`manage_master_user_password = true` on RDS,
  or `aws_secretsmanager_secret_rotation` with the AWS-provided rotation function).
- **Third-party tokens** (webhook secrets, SaaS API keys) usually cannot be rotated by AWS. Say so on
  the secret — `description = "chat-tool signing secret; rotated manually by <owner>, no API"` — and
  give it an owner. The control keeps failing; the reason is now visible to whoever reviews it.

**Breaks:** rotation changes the value under running clients. Clients must read the secret at call
time (or cache briefly), not once at start-up, before rotation is turned on.

---

## Plan checklist additions

- [ ] `aws_lambda_function_url` with `authorization_type = "NONE"` and no `Exposure` tag or no
      `reserved_concurrent_executions` on the function.
- [ ] `assign_public_ip = true` on an ECS service or task set.
- [ ] A container definition without `readonlyRootFilesystem = true`, without `user`, or without
      `logConfiguration`.
- [ ] `aws_ecr_repository` with mutable tags or without a lifecycle policy.
- [ ] A new bucket without a TLS-only policy, access logging or lifecycle rule.
- [ ] A new secret with neither rotation nor a description saying why not.
