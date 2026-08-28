# NOTICE — provenance of the code in this repository

This repository is a fork and carries code from several origins. This file records
which is which. See `LICENSE` for the terms that apply to each category.

## 1. Upstream (inherited, license unstated)

Forked from **[iamnolanhu/claude-dotfiles](https://github.com/iamnolanhu/claude-dotfiles)**
(Nolan Hu / Sigma Synapses) at commit `2237db2`, 2026-07-13. The upstream repository
publishes **no license file**, so the terms for these portions are unstated.

Inherited: the profile / `CLAUDE.md` assembly system, the `setup.sh` integration
registry, and these 18 skills —

`color-strategy` · `context-dump` · `design-taste` · `explore-plan-code-test` ·
`feature-gap-audit` · `first-principles` · `getting-started` · `humanizer` ·
`quick-commit` · `react-bits` · `reflection` · `responsive-audit` ·
`review-changes` · `scrapegraph` · `test-and-fix` · `uiverse` · `verify` · `verify-ui`

## 2. Vendored from named upstreams (their licenses apply)

| Source | What | Re-vendor with |
|---|---|---|
| [decolua/9router](https://github.com/decolua/9router) | 9 skills: `9router`, `-chat`, `-embeddings`, `-image`, `-stt`, `-tts`, `-video`, `-web-fetch`, `-web-search` | `scripts/vendor-9router-skills.sh` |
| [smarzban/herdr-file-viewer](https://github.com/smarzban/herdr-file-viewer) @ v1.15.0 | `skills/herdr-file-viewer` | see header comment in that SKILL.md |
| Siqi Chen | `skills/humanizer` — MIT, `skills/humanizer/LICENSE` | — |
| poteto | pstack skill pack | `scripts/vendor-pstack-skills.sh` |

Vendored files carry a header comment naming their source. Do not hand-edit them;
re-vendor instead.

## 3. Third-party software installed, not redistributed

This repository provisions but does not contain:

| Software | Role here | Source |
|---|---|---|
| `firstmate` | optional crew manager | [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate) |
| `herdr` | terminal workspace manager | https://herdr.dev |
| `9router` | model gateway | https://9router.com |
| `mel` | agentic terminal harness | https://openmel.dev |
| agent CLIs | `claude`, `codex`, `cursor-agent`, `cortex`, `opencode`, `gemini`, `pi`, `grok`, `kimi` | respective vendors |

Each carries its own license. Installing them is the user's action, performed by
scripts in this repository.

## 4. Everything else

Authored here since the fork point and covered by `LICENSE`: the review pipeline
(`isolate`, `fusion`, `council`, SHIPIT), the `ansible-ai/` fleet layer, the
`justfile`, the hooks, the test suites, and the remaining skills.
