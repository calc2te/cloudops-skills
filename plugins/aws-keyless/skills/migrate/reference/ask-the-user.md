# Ask the user before you dig

Much of what this migration needs is known instantly by a person and takes a long time to infer
from the outside. A code path you would reconstruct from CloudTrail in thirty minutes is one grep
away if someone tells you where the repository is.

## When to ask, when to look up

| | do this | examples |
|---|---|---|
| **only a person knows** | ask | where the code lives, how critical the service is, what the cron jobs are *for*, who approves a prod deploy |
| **quick to look up** | look it up, don't ask | cluster and service names, current task role, task definition, **which IAM user owns each key and its policies** |
| **people usually don't know** | check it yourself, then tell them | SES default configuration sets, resource policies naming the old user, KMS keys on buckets |

**Ask once, in one batch.** Collect every question you have at the start and present them
together, each with a one-line reason and a sensible default where one exists. Drip-feeding
questions one at a time is the fastest way to lose the person's attention.

Accept "I don't know" as an answer — note it, fall back to measurement, and say in the result which
parts were measured rather than confirmed.

## The questions

Ask the ones that apply. Skip any the repository already answers (`CLAUDE.md`, README, CI files).

### 1. Where is the application code? — ask this first

> "Is the application code available locally, or can you point me at the repository?
> Scanning it is the fastest and most accurate way to find which AWS services it calls."

Why it matters: the code lists every SDK client, bucket, table, queue and schedule — including
paths that have not run recently and would never show up in CloudTrail. With the code, CloudTrail
becomes a cross-check. Without it, CloudTrail is the only source and you will miss infrequent paths.

If the answer is yes, **scan before anything else**
([measuring-usage.md §5](measuring-usage.md#5-read-the-code)).

### 2. How critical is it?

> "If this service's AWS calls failed for a few hours, what breaks — and would customers notice?"

Decides one step vs. two phases ([SKILL.md](../SKILL.md#choose-the-pace)). Revenue, email to
customers, payments, data exports, anything with an SLA → two phases.

### 3. What runs on a schedule, and how often?

> "Are there cron jobs, queue workers or periodic tasks in this service? Anything weekly or monthly —
> billing, reports, newsletters, clean-ups?"

Sets the observation window. The longest schedule is the minimum wait before narrowing
permissions or deleting the old key. People forget monthly jobs; ask explicitly.

### 4. Which user-facing features touch AWS?

> "Does it send email, accept file uploads, generate download links, call an AI model, or export data?"

A plain-language feature list maps directly to services (email → SES, uploads → S3, links →
presigned URLs, AI → Bedrock) and surfaces the paths worth testing by hand after the switch.

### 5. How is it deployed, and what triggers production?

> "How do changes reach production — CI on a branch push, a tag, Terraform, manual? Is there staging?"

Tells you where the task definition / role binding must change (so the next deploy does not revert
it), whether a tag lands on a merge commit ([pitfalls §6](pitfalls.md#6-tags-on-merge-commits-may-not-contain-your-change)),
and whether you can rehearse on staging first.

### 6. Where do its secrets and settings come from — and is any key shared?

> "Where does the app get its environment — an SSM parameter, Secrets Manager, CI variables, a file in the image?
> Do you know whether any of its AWS keys are also used elsewhere — another service, staging, a person's laptop?"

The first half is where the static key has to be removed from, and where the resource names
(bucket, table, queue) are. The second half matters because a shared key cannot be deactivated
until every consumer has moved. Then **resolve each key's IAM user yourself** and read its policies
([measuring-usage.md §2](measuring-usage.md#2-inspect-the-key-being-replaced--its-permissions-are-what-the-app-runs-with-today)) —
people rarely know what a years-old key is allowed to do.

### 7. When is a safe time, and who can approve?

> "Is there a low-traffic window? Who needs to approve a production deploy, and who should be
> reachable while it rolls out?"

Production steps (removing a key, deploying) should not be taken on inference. Get a named approver.

### 8. Is there a way to test it already?

> "Is there an existing health or diagnostics page, or a test route (and does it sit behind extra
> authentication)?"

If yes, extend it instead of adding a new one. If a `/test` path is behind basic auth, you will need
those credentials — or the owner will need to open it.

## A good opening message

Keep it short, number the questions, give defaults, and say what you will do meanwhile:

> Before I change anything, a few quick questions — each saves a lot of guessing:
>
> 1. **Code**: is the repository available locally? (Scanning it is the most reliable way to find
>    what AWS it uses.)
> 2. **Criticality**: if AWS calls failed for a few hours, would customers notice?
>    *(Default if unsure: treat as critical → two-phase migration.)*
> 3. **Schedules**: any cron jobs or workers — especially weekly or monthly ones?
> 4. **Features**: does it send email, handle uploads, generate download links, or call AI models?
> 5. **Deploy**: how does it reach production, and is there a staging environment?
> 6. **Approval**: who approves the production deploy, and is there a quiet time window?
>
> Meanwhile I'll look up the cluster, task definition and current role, and trace each AWS key the
> app uses back to its IAM user and permissions — none of that needs you.
