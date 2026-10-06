# GitHub Actions: secrets → OIDC federation

> Status: **field-tested** — three repositories and a handful of roles migrated end to end
> (ECR push, ECS rolling and CodeDeploy blue/green deploys, SSM reads). The trust-policy
> conditions are still the part to get right; read them twice.

Prerequisites: [conventions](../reference/conventions.md), [pitfalls](../reference/pitfalls.md).

CI keys are the worst static keys you own: long-lived, broadly scoped, readable by anyone who can
modify a workflow, and usually shared across repositories. OIDC removes them entirely — GitHub
mints a short-lived token per job and AWS exchanges it for a session.

## Who does what

The work splits cleanly between two people, and often they are not the same person:

| | account admin | repository owner |
|---|---|---|
| does | measures the key, creates the role(s), verifies, disables the key | edits the workflow, merges, watches the first deploy |
| needs | IAM in the AWS account | write access to the repository |

If you are the **repository owner and a role has already been created for you**, jump to
[Quick path for repository owners](#quick-path-for-repository-owners). Everything else is the
admin's side.

## Quick path for repository owners

You were given a role ARN like `arn:aws:iam::<ACCOUNT>:role/<path>/oidc-github-<repo>-<env>`.
The role only accepts jobs from **your repository and the branch(es) it was created for** — ask
the admin which, if it was not stated.

1. In every workflow that uses `aws-actions/configure-aws-credentials`, add at the top level
   (above `jobs:`):

   ```yaml
   permissions:
     id-token: write   # lets the job request an OIDC token
     contents: read
   ```

   If the workflow already has a `permissions:` block, **add `id-token: write` to it** and keep
   the existing entries — a top-level `permissions:` replaces the defaults for every scope, so a
   job that pushes tags or comments on PRs needs those scopes listed too.

2. Replace the two key lines with the role:

   ```diff
          uses: aws-actions/configure-aws-credentials@v4
          with:
   -        aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
   -        aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
   +        role-to-assume: arn:aws:iam::<ACCOUNT>:role/<path>/oidc-github-<repo>-<env>
            aws-region: <REGION>
   ```

   Use the `-prod` role in the production workflow and the `-stage`/`-qa` role in the others —
   each one is refused by every other branch.

3. Merge the way you normally do. If your deploy workflows are identical on every branch, edit
   them once on the integration branch (e.g. `develop`) — each environment switches at its next
   deploy after the merge reaches it. Nothing else in the workflow changes; later steps (`aws`
   CLI, ECR login, ECS deploy actions) pick the session up automatically.

4. Tell the admin when each environment has deployed once. Do **not** delete the repository
   secrets yet — they are the rollback until the admin confirms.

If the job fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`, see
[Common failures](#common-failures). Rolling back is reverting this commit.

---

## Step 0 — Find every repository that uses the key

The secret's *value* is unreadable from GitHub, so a workflow that says
`secrets.AWS_ACCESS_KEY_ID` does not tell you *which* IAM user it is. Work from both ends:

**From the workflows** — list every workflow in the organisation that takes AWS credentials
(org-wide code search often returns nothing for private repositories; reading the files does):

```bash
for r in $(gh repo list <org> --limit 1000 --json name --jq '.[].name'); do
  gh api "repos/<org>/$r/contents/.github/workflows" --jq '.[].name' 2>/dev/null |
  while read f; do
    gh api "repos/<org>/$r/contents/.github/workflows/$f" --jq .content | base64 -d |
      grep -qiE 'aws-access-key-id|role-to-assume' && echo "$r/$f"
  done
done
```

**From CloudTrail** — keys used by GitHub-hosted runners show a user agent with
`configure-aws-credentials`, `github`, or a kernel string ending in `-azure`. Then map each key
to repositories by **what it touched**: the ECR repository it pushed to, the ECS service it
updated, the SSM parameter it read. Those names identify the workflow.

```sql
-- Athena over CloudTrail: which keys run on GitHub runners
SELECT useridentity.username, useridentity.accesskeyid, count(*) n, max(eventtime) last
FROM cloudtrail
WHERE useridentity.type = 'IAMUser'
  AND (lower(useragent) LIKE '%github%' OR lower(useragent) LIKE '%configure-aws-credentials%'
       OR useragent LIKE '%-azure%')
GROUP BY 1, 2 ORDER BY n DESC
```

Seen in practice:

- One "backend" CI key was shared by **five** repositories, deploying four different products.
- A user named `github-ecs-action` was not CI at all — a running container used it a million
  times a month. **Names lie; the user agent and source address do not.**
- Two keys for repositories already moved to OIDC were still active weeks later — one of them in
  the administrators group. Disabling leftovers is the cheapest win in this whole exercise.
- A key pair sat in an untracked file in a developer's clone, one `git add .` away from being
  committed. Look for stray credential files while you are in the repositories.

## Step 1 — Measure what each repository actually does

List every API the key called (CloudTrail, 30–90 days), grouped by repository via the resource
names. Then read the workflow files to confirm. Typical deploy workflow:

| workflow step | API calls | scope it to |
|---|---|---|
| ECR login | `ecr:GetAuthorizationToken` | `*` (no resource-level support) |
| image push | `ecr:BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`, `BatchGetImage`, `GetDownloadUrlForLayer` | the repository |
| render + register task definition | `ecs:RegisterTaskDefinition`, `ecs:DescribeTaskDefinition` | `*` (no resource-level support) |
| deploy to a rolling service | `ecs:DescribeServices`, `ecs:UpdateService` | the service |
| deploy to a **CODE_DEPLOY** service | `ecs:DescribeServices` + `codedeploy:GetDeploymentGroup`, `CreateDeployment`, `GetDeployment`; `RegisterApplicationRevision`/`GetApplicationRevision` on the application; `GetDeploymentConfig` | the deployment group / application — **no `ecs:UpdateService`** |
| pass roles in the task definition | `iam:PassRole` on the execution role and task role, condition `iam:PassedToService = ecs-tasks.amazonaws.com` | those roles |
| `.env` from SSM | `ssm:GetParameter` | the parameter(s) |

SSM SecureStrings encrypted with the AWS-managed `aws/ssm` key need **no** `kms:` statement; a
customer-managed key does.

## Step 2 — Roles: one per repository *and environment*

- **Per repository** — never share one role across repositories; the point is that CloudTrail
  then tells you which repository did what, something a shared key never allowed.
- **Per environment, not per branch** — one role per deployment target (`-prod`, `-stage`, `-qa`
  where it exists). A role per branch is more roles without more safety; one role for all
  environments lets a QA workflow overwrite production. Name: `oidc-github-<repo>-<env>`
  ([conventions](../reference/conventions.md)).

Trust policy — **both conditions are required**:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<ACCOUNT>:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": [
        "repo:<org>/<repo>:ref:refs/heads/release",
        "repo:<org>/<repo>:ref:refs/heads/qa"
      ]
    }
  }
}
```

🔴 Without the `sub` condition **any repository on GitHub** can assume your role. List the exact
deploy branches with `StringEquals` — a feature branch then cannot deploy anywhere.

| what you want to allow | `sub` value |
|---|---|
| specific branches | `repo:<org>/<repo>:ref:refs/heads/<branch>` (list several) |
| tags (tag-triggered deploys) | `repo:<org>/<repo>:ref:refs/tags/*` (`StringLike`) |
| one GitHub environment | `repo:<org>/<repo>:environment:production` |
| any ref in one repo (loose) | `repo:<org>/<repo>:*` (`StringLike`) — avoid for prod |

Never use `repo:<org>/*`. Never trust a personal account's repository for a company role.

**Verify before anyone uses it** — simulate both what must work and what must not:

```bash
aws iam simulate-principal-policy --policy-source-arn <stage role arn> \
  --action-names ecs:UpdateService --resource-arns <PROD service arn> \
  --query 'EvaluationResults[0].EvalDecision'      # expect implicitDeny
```

Check at least: stage → prod service, stage → prod ECR repository, stage → prod SSM parameter,
prod → another product's parameter. All must be `implicitDeny`.

## Step 3 — Workflow change

See [Quick path for repository owners](#quick-path-for-repository-owners) — hand that section to
the owner along with the role ARN(s) and the branches each accepts.

## Step 4 — Verify each environment

After the first deploy of each environment:

```bash
# who registered the new task definition
aws ecs describe-task-definition --task-definition <family> \
  --query 'taskDefinition.registeredBy'            # expect …assumed-role/oidc-github-<repo>-<env>/GitHubActions
# the key went quiet for this repository's resources
aws iam get-access-key-last-used --access-key-id <AKIA…>
```

For a shared key, "last used" only tells you about *all* consumers — check CloudTrail filtered to
this repository's ECR repository / service to confirm the key stopped deploying *it*.

## Step 5 — Finish

When **every** consumer of the key has moved (including non-GitHub ones you found in Step 0):
deactivate the key → wait through at least one deploy of each repository → delete the repository
secrets → delete the key and the IAM user.

## FAQ

**Is the role ARN a secret? What if someone learns it?** No. The ARN is an address, not a
credential. To assume the role a caller must present a token *signed by GitHub* whose `sub` GitHub
itself filled in with the repository and ref the job runs on — a workflow cannot choose it. Another
repository, a fork's pull request (`sub` is `…:pull_request`), or a laptop all fail. The real
boundary is **who can run a workflow on the trusted branch of that repository** — i.e. who has
write access to it. Compare a static key: whoever holds it can use it from anywhere until it is
disabled.

**Can a deleted or renamed repository be hijacked?** `sub` compares names. If the organisation
deletes the repository, someone could in theory recreate the name only if they control the
organisation — but a role trusting a *personal* account's repository is exposed if that account is
renamed or deleted. For stronger binding, customise the OIDC subject claim to include the
immutable `repository_id`.

## Cost attribution

Every GitHub OIDC session is named `GitHubActions` unless the workflow sets `role-session-name`.
Billing data that identifies callers by session name (e.g. Bedrock usage keyed on the IAM principal)
will lump all repositories together — group by the **role name** instead, or set a distinct
`role-session-name` per repository.

## Common failures

`Not authorized to perform sts:AssumeRoleWithWebIdentity`, in order of likelihood:

1. `id-token: write` missing — or a job-level `permissions:` block overrides the top-level one.
2. `sub` does not match the triggering ref — tag pushes are `refs/tags/…`, a `workflow_dispatch`
   from another branch carries *that* branch, pull requests are `…:pull_request`.
3. Wrong role for the workflow (stage role in the prod workflow).
4. Provider audience is not `sts.amazonaws.com`.

`AccessDenied` *after* assuming: a permission the key had that the measurement missed — the error
names it. Add that one statement; do not widen to `*`.
