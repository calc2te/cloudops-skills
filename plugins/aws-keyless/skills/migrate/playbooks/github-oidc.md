# GitHub Actions: secrets → OIDC federation

> Status: derived from the ECS playbook plus AWS/GitHub docs — not yet run end to end by the
> authors. The trust-policy conditions are the part to get right; read them twice.

Prerequisites: [conventions](../reference/conventions.md), [pitfalls](../reference/pitfalls.md).

CI keys are the worst static keys you own: long-lived, broadly scoped, readable by anyone who can
modify a workflow, and usually shared across repositories. OIDC removes them entirely — GitHub
mints a short-lived token per job and AWS exchanges it for a session.

## Step 0 — Context

Ask first — [ask-the-user.md](../reference/ask-the-user.md). For CI also ask: *which repositories and branches use this key?* and *are GitHub environments with approvals in use?* — they decide the `sub` condition.

```bash
# which workflows use static keys
grep -rn "AWS_ACCESS_KEY_ID" .github/workflows/

# does the account already have the provider?
aws iam list-open-id-connect-providers
```

Note every repository and branch that uses the key — one CI key is often shared by several repos,
and each needs its own role once you migrate.

## Step 1 — Measure

Find what the CI user actually does. A deploy key usually touches ECR, ECS, S3 and SSM, but
"usually" is not a policy — see [measuring-usage.md](../reference/measuring-usage.md) §2, then
read the workflow files to confirm.

## Step 1b — Read the CI user's permissions before designing the role

With CI there is no attached identity to be misled by — the key's IAM user **is** today's
permission set. It is usually the broadest key in the account and the least examined.

```bash
aws iam get-access-key-last-used --access-key-id <AKIA…> --query UserName --output text
aws iam list-attached-user-policies --user-name <CI_USER>
aws iam list-user-policies --user-name <CI_USER>
aws iam list-groups-for-user --user-name <CI_USER>     # admin often arrives via a group
```

Then check **who else uses it** — the same key is commonly pasted into several repositories, a
deploy script on a server, and someone's laptop. Access Advisor and `get-access-key-last-used` show
usage, not consumers; ask the user, and search the organisation's workflows for the secret name.

Design consequences:

- One OIDC role **per repository** (and per environment), each starting from what *that* repo's
  workflows actually do — not from the shared user's full policy.
- If you must bridge quickly, copy the user's policy into each repo role for phase 1, then narrow
  per repo. After the switch, CloudTrail attributes calls per repo (the role is per repo) — something
  the shared key never allowed.
- Do not deactivate the key until every consumer, including non-GitHub ones, has moved.

See [measuring-usage.md §2](../reference/measuring-usage.md#2-inspect-the-key-being-replaced--its-permissions-are-what-the-app-runs-with-today).

## Step 2 — Identity provider and role

One provider per account:

```
URL:      https://token.actions.githubusercontent.com
Audience: sts.amazonaws.com
```

Trust policy — **both conditions are required**:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<ACCOUNT>:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike": { "token.actions.githubusercontent.com:sub": "repo:<org>/<repo>:ref:refs/heads/main" }
  }
}
```

🔴 Without the `sub` condition **any repository on GitHub** can assume your role. Scope it as
tightly as the workflow allows:

| what you want to allow | `sub` value |
|---|---|
| one branch | `repo:<org>/<repo>:ref:refs/heads/main` |
| tags (tag-triggered deploys) | `repo:<org>/<repo>:ref:refs/tags/*` |
| one environment (recommended) | `repo:<org>/<repo>:environment:production` |
| any ref in one repo (loose) | `repo:<org>/<repo>:*` |

Prefer GitHub **environments** with required reviewers: the condition then also enforces approval.
Never use `repo:<org>/*`.

Name it `oidc-github-<repo>-<env>` per [conventions](../reference/conventions.md).

## Step 3 — Use the role in the workflow (keys still present)

```yaml
permissions:
  id-token: write        # required — without it no token is minted
  contents: read

steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::<ACCOUNT>:role<PATH>oidc-github-<repo>-<env>
      aws-region: <REGION>
```

Run the workflow once on a branch with the keys still configured; the action prefers the role, so
a failure here is safe to debug.

## Step 4 — Nothing to change in application code

The action exports temporary credentials as environment variables for the job. Anything that reads
the default chain works unchanged.

## Step 5 — Delete the repository secrets

Remove `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from the repo (and from the org, if they were
organisation-level). Search for other workflows that referenced them before deleting.

## Step 6 — Verify

```yaml
- run: aws sts get-caller-identity      # expect assumed-role/oidc-github-…/<run id>
```

The IAM user's key should go quiet:

```bash
aws iam get-access-key-last-used --access-key-id <AKIA…> \
  --query 'AccessKeyLastUsed.[LastUsedDate,ServiceName]' --output text
```

## Step 7 — Roll back, or finish

Roll back by re-adding the secret and reverting the workflow step. When every repository that used
the CI user has moved, deactivate the key, wait a day, then delete the key and the user.

**Common failure**: `Not authorized to perform sts:AssumeRoleWithWebIdentity`. In order of
likelihood — missing `id-token: write`, a `sub` that does not match the triggering ref (tag pushes
are `refs/tags/*`, not `refs/heads/*`), or the provider's thumbprint/audience being wrong.
