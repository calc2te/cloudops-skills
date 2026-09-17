# Denial alerting — wire this BEFORE narrowing a role's permissions.
#
# Two independent signals, because each misses things the other catches:
#   A. CloudTrail → EventBridge: AccessDenied on management-plane calls (IAM, KMS, Bedrock, SES
#      configuration …) made by the role. Near real-time.
#   B. Application log metric filter: "not authorized to perform" in the app's own logs. Catches
#      data-plane denials CloudTrail never records (S3 objects, SES sending, DynamoDB items, SQS).
#
# Without these, a missed permission surfaces as a user complaint the next morning.
# Replace: <ROLE_NAME> <LOG_GROUP> <ALERT_EMAIL> <WORKLOAD>

resource "aws_sns_topic" "denials" {
  name = "iam-denials-<WORKLOAD>"
}

resource "aws_sns_topic_subscription" "denials_email" {
  topic_arn = aws_sns_topic.denials.arn
  protocol  = "email" # or "https" to a chat webhook relay
  endpoint  = "<ALERT_EMAIL>"
}

# ── A. CloudTrail management events ─────────────────────────────────────────
# Requires a CloudTrail trail delivering management events (the default in most accounts).
resource "aws_cloudwatch_event_rule" "role_access_denied" {
  name        = "access-denied-<WORKLOAD>"
  description = "AccessDenied / UnauthorizedOperation for role <ROLE_NAME>"

  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      errorCode = ["AccessDenied", "AccessDeniedException", "UnauthorizedOperation", "Client.UnauthorizedOperation"]
      userIdentity = {
        sessionContext = {
          sessionIssuer = { userName = ["<ROLE_NAME>"] }
        }
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "role_access_denied" {
  rule      = aws_cloudwatch_event_rule.role_access_denied.name
  target_id = "sns"
  arn       = aws_sns_topic.denials.arn

  input_transformer {
    input_paths = {
      action   = "$.detail.eventName"
      source   = "$.detail.eventSource"
      message  = "$.detail.errorMessage"
      resource = "$.detail.requestParameters"
    }
    input_template = "\"<ROLE_NAME> denied <source>:<action> — <message>\""
  }
}

# EventBridge needs permission to publish to the topic.
resource "aws_sns_topic_policy" "denials" {
  arn = aws_sns_topic.denials.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.denials.arn
    }]
  })
}

# ── B. Application logs (data-plane denials) ────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "app_not_authorized" {
  name           = "not-authorized-<WORKLOAD>"
  log_group_name = "<LOG_GROUP>"
  # SDK error text is stable across languages: "User: arn:… is not authorized to perform: <action>"
  pattern = "\"not authorized to perform\""

  metric_transformation {
    name          = "NotAuthorized-<WORKLOAD>"
    namespace     = "IamMigration"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_not_authorized" {
  alarm_name          = "not-authorized-<WORKLOAD>"
  alarm_description   = "App logged an AWS authorization failure — likely a permission missed during migration"
  namespace           = "IamMigration"
  metric_name         = aws_cloudwatch_log_metric_filter.app_not_authorized.metric_transformation[0].name
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.denials.arn]
}

# Keep both for at least one full cycle of the longest scheduled job after narrowing.
# Remove them when the migration is closed, or keep them — a denial is always worth knowing about.
