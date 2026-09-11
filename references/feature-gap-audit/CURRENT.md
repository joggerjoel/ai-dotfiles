# Feature Gap Audit — Current State

**Last run:** 2026-09-11
**Run snapshot:** runs/2026-09-11.md

## TL;DR

qm is a hosted, multi-user agent platform for a company; ai-dotfiles is a provisioning and
config layer for an operator's own coding-agent CLIs and fleet. They are not substitutes.
The useful comparison is at the level of portable patterns: qm has a harness-independent
command policy, provenance-labelled injection screening, an audit log, and egress control
that ai-dotfiles lacks; ai-dotfiles has fleet provisioning, real observability, model-tier
routing, and a review pipeline that qm lacks. Highest-leverage move: make the command deny
policy apply to every harness, not just Claude.

## Side-by-side

| Dimension | qm | ai-dotfiles |
|---|---|---|
| Category | Hosted multi-user runtime (Slack + web), Postgres, Fastify | Per-machine config + fleet provisioning for local agent CLIs |
| Harnesses | 4 (pi, opencode, codex, claude) behind one `Harness` interface, switchable per turn | 11 CLIs installed side by side; no shared interface; fusion/council orchestrate via `claude -p` / `codex exec` |
| Rulebook | `CLAUDE.md -> AGENTS.md` symlink | Assembled `CLAUDE.md` linked into codex, opencode, gemini (`lib/links.sh`) |
| Memory | Built-in notebook, 3 strategies, pluggable providers (MCP, memorable), per-scope, benchmarked | claude-mem plugin + Claude auto-memory; single scope |
| Skills | Registry with draft/review/published, ACL grants, git packs at pinned ref with sync, admin promotion | 43 repo skills symlinked into `~/.claude` and `~/.codex`; vendored pins (`.upstream`); pstack sync; no lifecycle |
| Background work | Crons, watches, webhooks (5 verifiers), inbox loops, all in core | Shell crons (fleet update, marketplace refresh), `/loop`, scheduled-tasks plugin |
| Security posture | strict/auto/dangerous, org floor scopes can only tighten | Single `permissions` allow/deny list per profile |
| Command policy | `ORG_FLOOR_RULES`, harness-independent, quote/heredoc-aware | `permissions.deny` in Claude settings only |
| Injection screening | LLM classifier, provenance labels, quarantine, shadow mode, unscreened notice | Regex PostToolUse hook, shadow -> enforce, per-host baseline |
| Egress | Envoy proxy, per-scope allow/deny hosts, fail-closed | None |
| Audit | Postgres audit log, egress audit, credential-usage sink, admin views | None (claude-mem is partial history) |
| Sandbox | Per-scope durable sandbox, 8 backends | Agents run on the host; firstmate crewmate sandboxes only with the crew layer |
| Sessions | Postgres tape, session sharing | herdr on the always-on node (process-level persistence) |
| Model routing | Catalog + admin overlay + gateway transport + per-user creds | 3 tiers (subscription / 9router ~690 models / ollama); frontier never via gateway |
| Observability | Admin metrics/errors/audit views; no Prometheus | Prometheus + Grafana + Loki fleet stack; cache-guard statusline |
| Multi-user | Core feature | Single operator |
| Deployment | `qm` CLI, fly/aws/porter/docker/helm, terraform | ansible playbooks, `setup.sh`, pull-based from `origin/main` |
| Review discipline | Mandatory independent `/code-review`, dev-instance live QA, zero-comments rule | council / fusion / isolate / SHIPIT, pstack + superpowers, code-simplifier gate |
| CI | Sharded tests, eslint+oxlint+knip, PgBouncer, coauthor-trailer rejection | 330 tests + shellcheck + cold install, manual dispatch only |
| Contributions | Human-prose ADRs only | Cold-install reports |

## Gap log

### Shipped on main
- **One rulebook for every harness** (qm: `CLAUDE.md -> AGENTS.md`). Ours: `lib/links.sh:212-215`.
- **Command denial floor** for Claude (qm: `ORG_FLOOR_RULES`). Ours: `profiles/*/settings.json` deny list. Same items: recursive rm, force push, drop/truncate table.
- **Shadow-then-enforce injection screening** (qm: `runShadowScreen`). Ours: `hooks/injection-guard.py` `INJECTION_GUARD_MODE`.
- **Skills pinned from git** (qm: skill packs at pinned ref). Ours: `skills/unlazy/.upstream`, `scripts/vendor-*.sh`, `scripts/sync-pstack.sh`.
- **Layered private config** (qm: `deploy/layers/<org>/` + private fork). Ours: `base/` + `profiles/` + gitignored `.local/`.
- **Things qm lacks that we have:** ansible fleet provisioning, Prometheus/Grafana/Loki, 11 harnesses, model tiers with gateway blast-radius policy, council/fusion/isolate, cache-guard.

### Built (unmerged)
- None identified. Remote branches not inspected this run.

### In progress
- **Codex skill allowlist widening** (`setup.sh:942` `CODEX_SKILLS=(unlazy)` on main; session memory from 2026-09-11 says a symlink refactor with a wider list exists locally).

### Not started — from qm
| Priority | Gap | qm source | Notes |
|---|---|---|---|
| P1 | Harness-independent command policy | `src/policy/command-policy.ts` | Deny list is Claude-only today; codex/opencode/pi/gemini get nothing. Could be a shell wrapper or per-harness config emitted by `setup.sh`. |
| P2 | Provenance labels + "unscreened" notice on tool results | `src/security/security-posture.ts` `toolResultProvenance`, `unscreenedNotice` | Our guard only warns on a match; it never labels external content or says when it did not run. |
| P2 | Tool-call audit log | `src/audit/audit-log.ts` | Nothing records what agents ran across the fleet. Loki is deployed and could receive hook output. |
| P3 | Egress allow/deny per agent | `src/resolution/egress-policy.ts`, `deploy/egress-proxy/` | No control today; a leaked frontier token can reach anywhere. |
| P3 | Memory scoping / provider routing | `src/memory/provider-router.ts` | claude-mem is one global scope. Low value for a single operator. |
| P3 | Live-instance QA gate for behaviour changes | `.codex/skills/dev-instance` | We have `verify-ui`/`verify-tui` but no "real by default" instance rule. |
| P4 | Coauthor-trailer CI rejection | `.github/workflows/cicd.yml` | Only if the AI-attribution preference is "never". |
| P4 | Guard false positives on its own docstring and on security rubric text | this run | Allowlist `hooks/` and `**/security-posture*` or narrow the pattern. |
| Option | Provision qm as a fleet service | `deployment.md`, `cli/` | Same shape as 9router/firstmate playbooks. Only if multi-user Slack access is wanted. |

## Recommended priority order
1. Command policy for every harness (P1). Closes the biggest asymmetry with least design.
2. Provenance labelling in injection-guard, plus the false-positive allowlist (P2, P4).
3. Audit log via hooks into Loki (P2). Infrastructure already exists.
4. Decide whether qm is a provisioning target or just a reference (Option).

## Run history
| Date | Snapshot | Trigger |
|---|---|---|
| 2026-09-11 | runs/2026-09-11.md | `compare https://github.com/yc-software/qm` |
