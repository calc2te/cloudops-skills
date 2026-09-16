# ECS task role — template
#
# Conventions: reference/conventions.md
#   path <PATH> (e.g. /acme/) · name ecs-<task-definition>-<env> · environment suffix always written
#   actions from the code, resources from config/measurement, no *FullAccess, no default Resource "*"
#
# Applying this file alone attaches nothing to any service, so the blast radius is zero.
# Verify with `aws iam simulate-principal-policy` (assert allowed AND denied) before wiring it in.
#
# Replace: <ACCOUNT> <REGION> <PATH> <SERVICE> <ENV> and the resource names.

locals {
  ecs_role_path = "<PATH>"
  ecs_role_tags = {
    Project     = "<PROJECT>"
    Service     = "<SERVICE>"
    Team        = "<TEAM>"
    Environment = "<ENV_TAG>" # long form if that is your tag convention: production / staging
    ManagedBy   = "terraform"
  }
  # If the provider sets ignore_tags for some of these keys, drop them here and let your tagging
  # automation own them — listing them in both places makes the provider overwrite standard values.
}

# Only ECS tasks in this account+region may assume the role (confused-deputy protection).
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

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
  name               = "ecs-<SERVICE>-<ENV>"
  path               = local.ecs_role_path
  description        = "ECS task role for <SERVICE> (<ENV>). <one line: what this workload calls>"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
  tags               = local.ecs_role_tags
}

# With more than one environment, keep the shared statements in a local and branch only on the
# per-environment resources (table, queue, bucket). That is what stops stage and prod from drifting.
resource "aws_iam_role_policy" "app" {
  name = "<SERVICE>-<ENV>-app"
  role = aws_iam_role.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Converse / ConverseStream map to InvokeModel / InvokeModelWithResponseStream.
        # Cross-region inference profiles (global.*) route to several regions, so the
        # foundation-model ARN needs a region wildcard (it also matches the region-less form).
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:aws:bedrock:<REGION>:<ACCOUNT>:inference-profile/*",
          "arn:aws:bedrock:*::foundation-model/anthropic.*",
        ]
      },
      {
        Sid      = "S3Objects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "arn:aws:s3:::<BUCKET>/*"
      },
      {
        # Listing is granted on the bucket ARN, without /*
        Sid      = "S3List"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::<BUCKET>"
      },
      {
        # Only the operations the code performs. Read-only workloads stop at Get/Query/Scan.
        Sid      = "DynamoDb"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:PutItem"]
        Resource = "arn:aws:dynamodb:<REGION>:<ACCOUNT>:table/<TABLE>"
      },
      {
        Sid    = "SqsQueue"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:SendMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility",
        ]
        Resource = "arn:aws:sqs:<REGION>:<ACCOUNT>:<QUEUE>"
      },
      {
        # Scope sending to the verified identity, not to all of SES.
        Sid      = "SesSend"
        Effect   = "Allow"
        Action   = ["ses:SendRawEmail", "ses:SendEmail"]
        Resource = "arn:aws:ses:<REGION>:<ACCOUNT>:identity/<DOMAIN>"
      },
    ]
  })
}
