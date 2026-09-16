# Pitfalls — all of these were hit for real

Every one of them fails *quietly*. That is why they are worth reading before you start.

## 1. Wrong order kills the service 🔴

Remove the key first, attach the role second, and the container starts with **neither**.
Always: ① attach role → deploy → confirm → ② remove key → redeploy.

Most dangerous when the service had no task role at all before (`taskRoleArn: null`), because there
is no partial fallback.

## 2. Environment variables beat the task role 🔴

The SDK credential chain is: **env vars → `~/.aws` profile → ECS task role → EC2 metadata**.
A leftover `AWS_ACCESS_KEY_ID` in `.env` wins over the role, silently, forever.

- Apps that namespace their settings (`APP_AWS_ACCESS_KEY_ID`) are immune: the SDK does not know
  that name, so only the app's own code can pass it.
- Apps using the standard names must have them removed from the environment. Code changes alone
  are not enough.

## 3. Passing `credentials` with null values is a hard error

```
InvalidArgumentException: Credentials must be ... an associative array that contains "key", "secret"
```

Emptying the values is not the same as omitting the key. **Omit the whole `credentials` entry** to
fall through to the default chain.

The inverse is also worth knowing: framework integrations (Laravel's S3 disk, SQS connector, SES
mailer; similar layers elsewhere) wrap it in `if (!empty($key) && !empty($secret))`, so leftover
config entries do *not* error. They are still worth deleting — the day a value appears, it wins.

## 4. Config caching means the runtime never reads `.env`

If the image build runs a config-cache step (e.g. `php artisan config:cache`), the framework stops
reading `.env` at runtime — the values were frozen into a cached file at **build** time.

Consequences: the credentials you thought came from the environment are actually baked into the
image, and runtime-only settings (like `AWS_PROFILE`) have no effect in the deployed container.

## 5. Deleting a security group while another group references it deadlocks

If SG **A** is being deleted and SG **B** still references A, and you apply both changes at once,
Terraform tries to delete A first and then retries `DependencyViolation` for its whole timeout
(measured: 11 minutes before we intervened).

Split it: ① apply B's rule removal alone (`-target`) → ② delete A in the next apply.

## 6. Tags on merge commits may not contain your change

Where production deploys trigger on a tag push, the tag usually lands on a merge commit. Verify the
content, not the intent:

```bash
git show <tag>:.ecs/prod/task-definition.json | grep taskRoleArn
```

If the role line is missing but the key was already removed, production comes up with no
credentials at all.

## 7. No `concurrency` in the workflow = an old deploy can overwrite a new one

Push twice in quick succession and two pipelines run. Whichever *finishes* last wins, which can be
the one that built the **older** image. Seen in practice; fixed by cancelling the stale run.

## 8. You will find things that are already broken

Migrations surface pre-existing rot. One app's DynamoDB credentials referred to an access key that
did not exist in the account any more — every call had been failing for months and nobody noticed
(CloudTrail showed zero activity for that principal). Moving to a role fixed it by accident.

Check whether the key you are replacing is actually being used before you assume the feature works.

## 9. Config defaults can point at another environment

A production app with no `TABLE_NAME` set fell back to the code default — the **staging** table.
Granting the role access to that table would have made production quietly serve staging data.

Scope each environment's policy to its own resources. Then a missing setting fails loudly with
AccessDenied instead of succeeding against the wrong data.

## 10. Do not rely on the `default` profile locally

With no `AWS_PROFILE` set, the SDK uses the `default` profile. On a laptop that profile is often
stale or broken, producing confusing errors that look like the migration's fault.

Set the profile explicitly per project (`direnv`, a shell hook, or the container's environment).
An empty `default` is a feature: it fails immediately instead of using an unexpected identity.
