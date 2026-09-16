# Developer laptops: static keys → short-lived sessions

> Status: partially battle-tested — the SAML/profile mechanics and the failure modes below were
> hit for real. The IAM Identity Center path is documented but was unavailable in that account.

Prerequisites: [pitfalls](../reference/pitfalls.md) §2, §4, §10 are all about local credentials.

A key on a laptop is the hardest to revoke and the easiest to lose. Replace it with a session that
expires on its own. The good news: **application code needs no changes** if it already follows
the rule from [SKILL.md](../SKILL.md) — pass nothing, let the SDK resolve.

## Step 0 — Pick the mechanism

| Situation | Use |
|---|---|
| AWS Organizations available | **IAM Identity Center** + `aws sso login` — first choice, no extra tooling |
| No Organizations (standalone or reseller-managed account) | **SAML federation** with your IdP + a CLI helper such as `saml2aws` |
| Third-party IdP already in place (Okta, Entra, Google Workspace) | either of the above, driven by that IdP |

⚠️ Accounts bought through a reseller are frequently *not* in an Organization you control. Identity
Center's account-level instance does **not** support permission sets or AWS account assignment, so
the SAML path is the realistic one there. Check before designing around it.

## Step 1 — Measure who is using keys

```bash
# every user key and when it was last used
aws iam list-users --query 'Users[].UserName' --output text | tr '\t' '\n' | while read u; do
  aws iam list-access-keys --user-name "$u" \
    --query "AccessKeyMetadata[].[UserName,AccessKeyId,Status,CreateDate]" --output text
done
```

Then `aws iam get-access-key-last-used` per key. Sort by age: keys created years ago and still
active are where to start. Include non-developers — analysts and PMs often hold keys too.

## Step 2 — Roles for people

Name them `sso-<idp>-<role>` (no environment suffix — see
[conventions](../reference/conventions.md)). Start with two or three: admin, developer, read-only.
Do **not** give everyone administrator because it is easier to set up once.

SAML trust policy:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<ACCOUNT>:saml-provider/<PROVIDER>" },
  "Action": "sts:AssumeRoleWithSAML",
  "Condition": {
    "StringEquals": { "SAML:aud": "https://signin.aws.amazon.com/saml" }
  }
}
```

Set the maximum session duration deliberately — the console allows up to 12 hours; shorter is
better if people tolerate it.

## Step 3 — Hand out a one-page setup

What each person does once:

```bash
brew install saml2aws        # or the Identity Center equivalent: nothing to install

saml2aws configure --idp-provider <IdP> --mfa Auto \
  --url "<IdP SSO URL>" --username <email> --profile <PROFILE> --region <REGION>
```

And once a day:

```bash
saml2aws login --profile <PROFILE>      # or: aws sso login --profile <PROFILE>
```

The helper writes temporary credentials into `~/.aws/credentials` under that profile. Every tool
that reads the standard chain — CLI, boto3, the AWS SDK for PHP/JS, Claude Code — then works
unchanged.

## Step 4 — Make the profile selection automatic

Per-project, so people are never in the wrong account:

```bash
# .envrc (direnv), not committed if the profile name is personal
export AWS_PROFILE=<PROFILE>
```

Framework caveat: putting `AWS_PROFILE` in a framework `.env` file works locally **only if the
config is not cached** (see [pitfalls](../reference/pitfalls.md) §4). A shell-level variable has no
such caveat, which is why it is the better default.

Containers: the credentials live on the host, so mount them read-only and pass the profile.

```yaml
volumes:
  - ~/.aws:/root/.aws:ro
environment:
  - AWS_PROFILE=<PROFILE>
```

## Step 5 — Remove the static keys

Deactivate first (instant rollback), delete a few days later. Remove the matching profiles from
`~/.aws/credentials` as well, or the old key silently keeps being used by anything that names that
profile.

Leave the `default` profile **empty**. An unset `AWS_PROFILE` then fails loudly instead of using
whatever identity happens to be first — see [pitfalls](../reference/pitfalls.md) §10.

## Step 6 — Verify

```bash
aws sts get-caller-identity --profile <PROFILE>
# expect assumed-role/<role>/<your email> — the session name carries the person's identity,
# which is exactly what CloudTrail (and per-person cost attribution) needs
```

That last point is the argument that convinces finance as well as security: with shared static
keys, CloudTrail shows one principal for everyone. With federation, every call carries the
individual's identity.

## Step 7 — Watch out for credential managers

GUI tools that "manage AWS profiles" may rewrite `~/.aws/credentials` wholesale. One such tool
deleted five unrelated profiles on first run. Before trying one: copy the file, and check what it
writes on a throwaway profile first.
