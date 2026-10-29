# Pitfalls

Things that pass review, often pass `plan`, and break a standard — or production — without an error
message. Ordered roughly by cost.

## 1. A rename is a replacement

Immutable after creation: SG `name` and `description`, ALB and target group `name`, IAM role `name`
and `path`, ECS cluster `name`, RDS identifiers. Terraform cannot update them, so it destroys and
recreates — detaching ENIs, invalidating ARNs other systems hold, breaking listener rules.

**Read every `must be replaced` in the plan.** If the cause is a name, revert the name. Bringing an
old resource to the new standard is never worth a replacement on its own.

## 2. Fixed `name` + `create_before_destroy` cannot coexist

Names are unique (per VPC for SGs, per account-region for ALBs/TGs). A replacement that creates
before destroying collides with itself. Use `name_prefix` on SGs (readable name in the `Name` tag).
For target groups behind a listener, `name_prefix` is limited to 6 characters — either accept a
generated name or plan the replacement as two applies.

## 3. Length limits fail at `apply`, not `plan`

ALB and target group names: 32 characters. IAM role names: 64. SG rule descriptions: 255. Add
`validation` blocks on the variables that build names so the failure happens at `plan`, before half
an apply has run.

## 4. SG rule descriptions are ASCII only

Non-ASCII characters (accents, Korean, emoji) are accepted by `plan` and rejected by the EC2 API.
Write descriptions in plain English.

## 5. No egress rule means no egress

Terraform removes AWS's default allow-all egress from SGs it creates. A new `app` SG without an
egress rule starts tasks that cannot pull from ECR — they stop with `CannotPullContainerError`
(i/o timeout), which looks like a registry or NAT problem rather than an SG one.

## 6. IPv6 is a separate field

`cidr_ipv4 = "0.0.0.0/0"` and `cidr_ipv6 = "::/0"` are two rules. A scanner, a review or a fix that
looks only at IPv4 leaves the IPv6 rule open. Check both every time.

## 7. Inline rules and rule resources fight

An SG with inline `ingress {}` blocks and also `aws_vpc_security_group_ingress_rule` resources
flip-flops forever: each apply removes the other's rules. Pick rule resources, everywhere.

## 8. `default_tags` doesn't reach ECS tasks or ASG volumes

Fargate cost is billed against the task. Without `propagate_tags = "SERVICE"` on the service, the
largest line of an ECS account is unattributed while every resource in the code looks tagged. ASG
`propagate_at_launch` covers instances only — volumes and ENIs need launch template
`tag_specifications`.

## 9. Tag values are case-sensitive in the bill

`ManagedBy = "Terraform"` from one root and `"terraform"` from another are two groups in every cost
report. Keep all values lowercase; grep the repository for capitalised values when adopting the
standard.

## 10. Console fixes are reverted

Tags, SG rules, role policies edited by hand are restored to the code's version on the next `apply`.
For tags that is a reporting glitch; for an SG rule someone opened during an incident, the port
closes again on the next unrelated deploy.

## 11. `ignore_tags` hides drift

Every key in `ignore_tags` is a key Terraform stops checking. Keep it to keys another process owns.
Listing a key there **and** in a resource's `tags` means the resource value is silently never applied.

## 12. Two owners of one ECS service

If CI registers task definitions and Terraform also manages `task_definition` or `desired_count`,
each run undoes the other — Terraform rolls the service back to an old image, or scales an
autoscaled service back to its initial count. `ignore_changes = [task_definition, desired_count]`.

## 13. A role attached is not a role in use

If the container also has `AWS_ACCESS_KEY_ID` in its environment, the SDK uses the key and the task
role is bypassed. A clean Terraform role says nothing about what the app actually runs with. Moving
off keys: the **aws-keyless** plugin.

## 14. Trust policy without a condition

An OIDC trust without a `sub` condition lets any GitHub repository assume the role. A service trust
without `aws:SourceAccount` is open to confused-deputy use from another account's resources. Both
are valid JSON and work perfectly in testing.

## 15. Data-tier egress

A `data` SG with `egress 0.0.0.0/0` copied from the app SG module defeats the one rule that cuts an
exfiltration path. When a module builds SGs for several tiers, make egress depend on the tier.
