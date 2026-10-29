# Organisation values

The skill carries no organisation's vocabulary. Each repository says it once, in `CLAUDE.md` (or
`AGENTS.md`), and every session reads it from there.

Paste this block and fill it in. Keep the lists **closed**: a value that is not listed is not
allowed, and adding one is a deliberate change.

```markdown
## AWS standards

Follows the aws-terraform-standards skill. Values for this organisation:

- account 123456789012 · region ap-northeast-2 · CLI profile `acme`
- products: `acme` | `widgets`                      ← first segment of every service ID
- internal tools (not a product): `<business area>-<tool>`, e.g. `ops-billing`
- IAM role path: `/acme/`
- environments (name → tag): prod → production · stage → staging · qa → qa · dev → development

### Project (closed list — which line of business pays)
- acme: `core` `checkout` `search`
- widgets: `widgets-api` `widgets-mobile`
- shared: `infra` `internal-tools` `account-shared`

### Team (closed list — who operates it)
`platform` `payments` `growth` `data`

### Tags set outside Terraform (go in ignore_tags)
`Lifecycle` (cleanup scripts mark delete candidates)
```

## How to choose `Project` when it is not obvious

Ask in this order and stop at the first yes:

1. Is it part of something a customer uses?
   - built only for one line of business → that line's value
   - running on the shared core platform → the core value
2. Is it a tool only employees use? → `internal-tools`
3. Is it an architectural component rather than a service (NAT, VPN, ingress, monitoring)? → `infra`

Asking 2 and 3 first makes product cost leak into `infra`. A large share on the core value is not a
failure to split — it tells you how much is genuinely shared.

## Why closed lists

Tags are the only way to split an AWS bill by owner when you cannot use AWS Organizations features
(a reseller sub-account, for example). The bill records the tag value **at the time of use**:
fixing a typo next month does not fix this month. Every free-form value becomes an unattributed row.
