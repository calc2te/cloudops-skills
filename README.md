# cloudops-skills

Claude Code skills for cloud governance work that nobody has time for.

| plugin | what it does |
|---|---|
| **[aws-keyless](plugins/aws-keyless)** | replace static AWS access keys with roles and short-lived credentials, across ECS, EC2, Lambda, CI and developer laptops |
| **[aws-terraform-standards](plugins/aws-terraform-standards)** | write AWS Terraform to one naming, tagging, security group and IAM role standard, and catch the plan changes that silently break it |

```
/plugin marketplace add calc2te/cloudops-skills
/plugin install aws-keyless@cloudops-skills
/plugin install aws-terraform-standards@cloudops-skills
```

Then describe the work; the right skill loads when it is relevant:

> "migrate the api service off its static key onto a task role"
> "our CI still uses an AWS access key — move it to OIDC"
> "add a terraform module for the new checkout service — ALB, ECS, its own role"
> "review this plan against our tagging and security group rules"

To enable it for everyone working in a repo, commit the two keys from
[app-repo-settings.json](app-repo-settings.json) into that repo's `.claude/settings.json` —
then nobody runs install commands at all.

## Why this exists

### aws-keyless

Static keys in `.env` files, container images and CI secrets are the most common way AWS
credentials leak, and "we should fix that" rarely survives contact with a running service. The
blockers are never conceptual:

- nobody knows what the workload actually calls, so nobody can write a safe policy
- one role is shared by a dozen services, so it cannot be narrowed
- a wrong step takes production down, so it never starts

The plugin encodes a procedure that handles all three, plus the failures that happen *silently*.

### aws-terraform-standards

Naming and tagging standards usually live in a wiki page nobody opens while writing Terraform, and
the expensive mistakes are not in the standard anyway — they are in how Terraform behaves: a
changed SG description replaces the SG, an SG with no egress rule has no egress, `default_tags`
never reaches Fargate tasks, a 33-character target group name passes `plan`.

The plugin puts both where the code is written: one service ID per deployable unit, every name and
tag generated from it, tier-based security groups, one role per workload — and a plan checklist for
the failures that do not raise an error. Organisation values (products, tag value lists, IAM path)
are read from the repository's `CLAUDE.md`, not baked in.

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

plugins/aws-terraform-standards/skills/standards/
├── SKILL.md            the 12 rules in short + a plan checklist
├── reference/
│   ├── configuration.md    the CLAUDE.md block holding your organisation's values
│   ├── naming.md           service ID, per-resource name templates, length limits
│   ├── tagging.md          required tags, Service values, where default_tags does not reach
│   ├── security-groups.md  tiers (edge/app/data/client), 6 rules, Terraform shape
│   ├── iam-roles.md        path, names, permission and trust rules
│   └── pitfalls.md         15 ways Terraform breaks the standard without an error
└── templates/          providers.tf, an ECS service, an edge→app→data SG chain (terraform validate clean)
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

No account values are baked in. The skills ask for what they need, or read it from the repo —
writing it into your project's `CLAUDE.md` once is the least annoying option (aws-terraform-standards
has a fuller block with tag value lists in
[configuration.md](plugins/aws-terraform-standards/skills/standards/reference/configuration.md)):

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

**aws-terraform-standards** — AWS 테라폼을 쓸 때 이름·태그·보안그룹·IAM 역할 표준을 적용하는 스킬이다.

- **서비스 ID 하나에서 모든 이름과 태그를 만든다.** `<제품>-<배포 단위>`(리포 이름 기준), 환경은 prod 까지 항상 명시.
- **태그는 코드가 갖는다.** `default_tags` 에 Project·Team·Environment, 리소스마다 Service. ECS 태스크·ASG 볼륨은 따로 전파해야 한다.
- **보안그룹은 포트가 아니라 계층(edge/app/data/client)으로.** 인터넷은 edge 만, data 는 아웃바운드 없음.
- **plan 점검표** — 이름 변경이 곧 교체, 기본 egress 제거, 길이 제한 등 에러 없이 깨지는 것들.
- 회사 고유 값(제품·태그 값 목록·IAM 경로)은 리포 `CLAUDE.md` 에서 읽는다.

**aws-keyless** — 정적 AWS 키를 역할·임시 자격증명으로 바꾸는 Claude Code 스킬이다. ECS·EC2·Lambda·CI·로컬 개발을 다룬다.

- **순서가 전부다.** 새 신원 부여·배포가 먼저, 키 제거·재배포가 나중. 뒤집으면 워크로드가 죽는다.
- **세션 이름으로 CloudTrail을 가른다.** 공유 역할이어도 서비스별 호출을 실측할 수 있다.
- **진단 엔드포인트를 같이 넣는다.** 전환 전후로 "지금 누구 자격으로 부르는가"를 화면으로 확인한다.

플레이북마다 실전 검증 여부를 명시해 두었다. ECS는 프로덕션에서 끝까지 돌려본 것이고,
EC2·Lambda·CI는 같은 뼈대로 도출한 것이다. 계정 고유 값은 들어 있지 않다.
