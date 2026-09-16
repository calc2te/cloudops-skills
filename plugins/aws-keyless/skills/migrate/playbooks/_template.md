# <platform>: static keys → <identity mechanism>

> Copy this file when adding a platform. Keep the step numbering — readers move between playbooks
> and the shape should not change. Delete guidance in quotes as you fill it in.
>
> State honestly at the top whether this has been run end to end, or is derived from the ECS
> playbook and AWS docs. Readers are about to touch production.

Prerequisites: [conventions](../reference/conventions.md), [pitfalls](../reference/pitfalls.md).

## Step 0 — Collect the context you need

> Table of what must be known before starting: account, region, profile, the resource identifier
> for this platform (instance id / function name / repo), and **who owns the definition** — the
> thing that would overwrite a manual change on the next deploy.

## Step 1 — Measure what it actually calls

> Platform-specific attribution. What identifies this workload in CloudTrail?
> (ECS: task ID as the session name. EC2: instance id in the session name. Lambda: function name.)
> Link to [measuring-usage.md](../reference/measuring-usage.md) for the general technique.

## Step 2 — Create the role and a narrow policy (attached to nothing → zero risk)

> The trust policy differs per platform; show it. Reuse
> [terraform-role.tf](../templates/terraform-role.tf) for the policy body.
> Always: verify with `aws iam simulate-principal-policy`, asserting allowed **and** denied.

## Step 3 — Attach the new identity (behaviour does not change yet)

> How the identity binds on this platform, and how to confirm it took effect.
> The old key still wins at this point — that is intentional.

## Step 4 — Stop the code from passing credentials

> Where this platform's SDK picks credentials up, and what to delete. No "use key if present"
> branches.

## Step 5 — Remove the key and reload

> Where the key physically lives on this platform, and what "reload" means here (redeploy,
> instance replacement, function update…).

## Step 6 — Verify

> The platform's equivalent of "who am I calling as", plus what a failure looks like in logs.

## Step 7 — Roll back, or finish

> The exact rollback command and how long it takes. Then: idle period before deleting the old key,
> and what to record.
