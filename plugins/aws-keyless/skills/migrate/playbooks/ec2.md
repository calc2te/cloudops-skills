# EC2: static keys → instance profile

> Status: derived from the ECS playbook plus AWS docs — not yet run end to end by the authors.
> The structure holds; verify each command in your account before trusting it with production.

Prerequisites: [conventions](../reference/conventions.md), [pitfalls](../reference/pitfalls.md).

## Step 0 — Context

Ask first — [ask-the-user.md](../reference/ask-the-user.md). For EC2 also ask: *is the instance hand-built, or in an Auto Scaling group / launch template?* and *which OS users run the app?* (keys hide in their home directories).

| Needed | How to get it |
|---|---|
| instance id(s) | `aws ec2 describe-instances --filters Name=tag:Name,Values=<NAME> --query 'Reservations[].Instances[].[InstanceId,IamInstanceProfile.Arn]' --output text` |
| who manages the instance | Terraform/CDK, an Auto Scaling launch template, or hand-built? A launch template change only affects **new** instances |
| where the key lives | userdata, `~/.aws/credentials` on the box, app config, or a baked AMI |

An Auto Scaling group is the common trap: editing a running instance fixes nothing permanently,
and editing the launch template fixes nothing immediately.

## Step 1 — Measure

EC2 sessions appear in CloudTrail as `assumed-role/<role>/<instance-id>` when a role is already
attached. If the instance uses a static key, look the key up instead — see
[measuring-usage.md](../reference/measuring-usage.md) §2.

```bash
aws iam get-access-key-last-used --access-key-id <AKIA…> \
  --query 'AccessKeyLastUsed.[LastUsedDate,ServiceName,Region]' --output text
```

## Step 2 — Role and policy

Same policy body as [terraform-role.tf](../templates/terraform-role.tf); only the trust differs:

```json
{
  "Effect": "Allow",
  "Principal": { "Service": "ec2.amazonaws.com" },
  "Action": "sts:AssumeRole"
}
```

EC2 needs an **instance profile** wrapping the role (Terraform: `aws_iam_instance_profile`;
the console creates one implicitly, the CLI does not).

Name it per [conventions](../reference/conventions.md): `ec2-<workload>-<env>`.

## Step 3 — Attach (no behaviour change yet)

```bash
aws ec2 associate-iam-instance-profile \
  --instance-id <ID> --iam-instance-profile Name=<PROFILE>
aws ec2 describe-instances --instance-ids <ID> \
  --query 'Reservations[].Instances[].IamInstanceProfile.Arn' --output text
```

Attaching is live and does not restart anything. If the instance is in an ASG, also update the
**launch template** so replacements inherit it.

## Step 4 — Stop passing credentials

Same rule as everywhere: remove explicit credentials from the code and let the SDK chain reach
instance metadata. On EC2 the chain ends at IMDS, so also confirm metadata access is not blocked:

```bash
# on the instance — IMDSv2
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

If that returns nothing, the role is not attached or IMDS is disabled (`HttpEndpoint`).
If your SDK is old and IMDSv2 is enforced (`HttpTokens: required`), upgrade the SDK — do not
loosen the metadata settings.

## Step 5 — Remove the key

Check every hiding place: `~/.aws/credentials` for each OS user, `/etc/environment`, systemd unit
`Environment=` lines, the app's `.env`, userdata (`aws ec2 describe-instance-attribute
--attribute userData`), and any baked AMI. Restart the service so it re-resolves credentials.

## Step 6 — Verify

```bash
# on the instance
aws sts get-caller-identity          # expect assumed-role/<role>/<instance-id>
```

Then watch application logs for `AccessDenied` and widen the policy from the messages.

## Step 7 — Roll back, or finish

Roll back by restoring the key file and restarting the service; detaching the profile is not
required. Once the old key has been idle for a day, deactivate it, then delete it.

**Also worth doing while you are here**: require IMDSv2 (`HttpTokens=required`) and set
`HttpPutResponseHopLimit=1` so a compromised container cannot reach the instance's credentials.
