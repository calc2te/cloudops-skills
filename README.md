# cloudops-skills

Claude Code skills for cloud governance work that nobody has time for.

Currently one plugin: **[aws-keyless](plugins/aws-keyless)** — replace static AWS access keys with
roles and short-lived credentials, across ECS, EC2, Lambda, CI and developer laptops.

```
/plugin marketplace add calc2te/cloudops-skills
/plugin install aws-keyless@cloudops-skills
```

Then describe the work; the skill loads when it is relevant:

> "migrate the api service off its static key onto a task role"
> "our CI still uses an AWS access key — move it to OIDC"
> "scope this role down to what the service actually uses"

To enable it for everyone working in a repo, commit the two keys from
[app-repo-settings.json](app-repo-settings.json) into that repo's `.claude/settings.json` —
then nobody runs install commands at all.

## Why this exists

Static keys in `.env` files, container images and CI secrets are the most common way AWS
credentials leak, and "we should fix that" rarely survives contact with a running service. The
blockers are never conceptual:

- nobody knows what the workload actually calls, so nobody can write a safe policy
- one role is shared by a dozen services, so it cannot be narrowed
- a wrong step takes production down, so it never starts

The plugin encodes a procedure that handles all three, plus the failures that happen *silently*.

## Structure

```
plugins/aws-keyless/skills/migrate/
├── SKILL.md            entry point — which platform → which playbook, plus the 4 universal rules
├── reference/          platform-independent
│   ├── conventions.md      role paths, naming, policy rules, action mappings people get wrong
│   ├── pitfalls.md         10 failures that happen silently
│   └── measuring-usage.md  how to learn what a workload really calls
├── playbooks/          one per platform, same 7-step shape
│   ├── ecs.md              task role            ← run end to end in production
│   ├── ec2.md              instance profile
│   ├── lambda.md           execution role
│   ├── github-oidc.md      CI federation
│   ├── local-dev.md        developer sessions   ← partially battle-tested
│   └── _template.md        for adding a platform
└── templates/          Terraform role + policy, diagnostics endpoints (FastAPI, Laravel)
```

Each playbook states honestly whether it has been run end to end or derived from the ECS one.
Readers are about to touch production; they deserve to know which is which.

## The three ideas worth stealing

**Order is everything.** Grant the new identity and deploy *first*; remove the key and deploy
*second*. Reversed, the workload starts with no credentials at all.

**A task role session is named after the task ID.** That is how you attribute CloudTrail to one
service while twenty share a role — which is how a narrow policy gets written from evidence
instead of guesswork. Every platform has an equivalent handle.

**Ship a diagnostics endpoint with the migration.** One page printing the calling identity and a
pass/fail per AWS service turns "did it work?" into something the owning team answers by itself.

## Configuration

No account values are baked in. The skill asks for what it needs, or reads it from the repo —
writing it into your project's `CLAUDE.md` once is the least annoying option:

```markdown
## AWS
- account 123456789012 · region ap-northeast-2 · CLI profile acme
- IAM role path prefix `/acme/`, names `ecs-<task-definition>-<env>`
- ECS task definitions live in `.ecs/<env>/task-definition.json`, registered by CI
```

## Where it came from

Extracted from migrating a production account with the usual debt: one shared ECS role used by 15
services carrying `SecretsManagerReadWrite` and `AmazonSSMFullAccess`, static keys baked into
images by CI, and no way to tell from CloudTrail which service did what.

Five services moved to dedicated roles and two long-lived keys went idle. Two findings were not in
the plan: a feature that had been failing for months against a **deleted** access key, and a
production app reading the **staging** table because a config default filled in a missing setting.
Both surfaced only because the work forces you to enumerate what each service really touches.

## Contributing

Adding a platform is filling in [_template.md](plugins/aws-keyless/skills/migrate/playbooks/_template.md).
Keep the step numbering — readers move between playbooks and the shape should not change.

## License

MIT — see [LICENSE](LICENSE).

---

## 한국어 요약

정적 AWS 키를 역할·임시 자격증명으로 바꾸는 Claude Code 스킬이다. ECS·EC2·Lambda·CI·로컬 개발을 다룬다.

- **순서가 전부다.** 새 신원 부여·배포가 먼저, 키 제거·재배포가 나중. 뒤집으면 워크로드가 죽는다.
- **세션 이름으로 CloudTrail을 가른다.** 공유 역할이어도 서비스별 호출을 실측할 수 있다.
- **진단 엔드포인트를 같이 넣는다.** 전환 전후로 "지금 누구 자격으로 부르는가"를 화면으로 확인한다.

플레이북마다 실전 검증 여부를 명시해 두었다. ECS는 프로덕션에서 끝까지 돌려본 것이고,
EC2·Lambda·CI는 같은 뼈대로 도출한 것이다. 계정 고유 값은 들어 있지 않다.
