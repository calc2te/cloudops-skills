# Task/instance role skeleton — role + trust only.
#
# The policy body is deliberately almost empty. Add **only** the statements this workload was
# measured using: pick them from templates/policy-snippets.md and paste them in.
# A template that pre-lists S3 + DynamoDB + SQS + SES teaches the opposite of least privilege.
#
# Naming and path: reference/conventions.md
# Replace: <ACCOUNT> <REGION> <PATH> <WORKLOAD> <ENV>

locals {
  role_path = "<PATH>" # e.g. /acme/ — marks roles a human created on purpose
  role_tags = {
    Project     = "<PROJECT>"
    Service     = "<WORKLOAD>"
    Team        = "<TEAM>"
    Environment = "<ENV_TAG>"
    ManagedBy   = "terraform"
  }
  # If the provider sets ignore_tags for some of these keys, leave those keys out here —
  # listing them in both places makes the provider overwrite your standard values.
}

# Trust: pick the principal for the platform you are on.
#   ECS task role    → ecs-tasks.amazonaws.com   (+ SourceAccount/SourceArn, below)
#   EC2              → ec2.amazonaws.com         (also needs aws_iam_instance_profile)
#   Lambda           → lambda.amazonaws.com
#   GitHub Actions   → federated OIDC            (see playbooks/github-oidc.md)
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Confused-deputy protection: only ECS in *this* account and region may assume the role.
    # Keep these for any service principal that supports them.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = ["<ACCOUNT>"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:<REGION>:<ACCOUNT>:*"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "ecs-<WORKLOAD>-<ENV>"
  path               = local.role_path
  description        = "Task role for <WORKLOAD> (<ENV>). <one line: what this workload calls>"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = local.role_tags
}

# ── Permissions ──────────────────────────────────────────────────────────────
# Delete this resource entirely if the workload makes no AWS calls — plenty of services don't,
# and a role with no policy is a perfectly good answer.
#
# Otherwise paste one statement per AWS service the workload actually uses.
# Source: templates/policy-snippets.md
resource "aws_iam_role_policy" "app" {
  count = 0 # ← set to 1 once you have real statements below

  name = "<WORKLOAD>-<ENV>-app"
  role = aws_iam_role.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # example shape — replace with measured statements from policy-snippets.md
      {
        Sid      = "ExampleReplaceMe"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::<BUCKET>/<PREFIX>/*"
      },
    ]
  })
}

# ── Multiple environments ────────────────────────────────────────────────────
# Keep shared statements in a local and branch only on per-environment resources. That is what
# stops stage and prod policies from drifting apart:
#
#   locals {
#     app_common = [ /* statements identical in both */ ]
#     app_env = {
#       stage = { Sid = "Table", Effect = "Allow", Action = [...], Resource = ".../table/app-stage" }
#       prod  = { Sid = "Table", Effect = "Allow", Action = [...], Resource = ".../table/app" }
#     }
#   }
#   policy = jsonencode({ Version = "2012-10-17"
#                         Statement = concat(local.app_common, [local.app_env.prod]) })
