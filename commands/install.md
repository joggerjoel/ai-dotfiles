---
description: Agentic install/verify of this machine as an AI-workforce host (reads the setup log, fixes gaps, interactive on request)
---

# /install [interactive]

You are finishing and verifying the installation of this machine as an AI-workforce
host (ai-dotfiles). The deterministic stage already ran (or will be run by you);
your job is oversight: read what happened, close the gaps, and report honestly.

Mode: "$ARGUMENTS" — if it contains `interactive`, use the human-in-the-loop flow
(ask the user questions with AskUserQuestion before acting). Otherwise run one-shot
and only stop for genuinely blocking decisions.

## Workflow

1. **Prime.** Read the ai-dotfiles README.md and `git log --oneline -5` to know what
   this repo currently is. Do not deep-dive the whole tree.
2. **Deterministic stage.** If `~/.claude/logs/setup.log` has no `setup-init` entries
   from the last hour, run `scripts/setup-init.sh` yourself. Then read the log tail
   (last 40 lines) — it is the source of truth for what is present/missing.
3. **Close required gaps.** For each `missing` REQUIRED tool (git jq curl node claude
   just): install it the repo way — `./setup.sh` owns installs (`ensure_*` functions);
   never hand-roll a different install path. Optional tools (codex pi grok opencode
   gh bun uv herdr tmux): list them, install only if the user wants them (interactive)
   or skip with a note (one-shot).
4. **Interactive mode only:** ask (AskUserQuestion, batches of ≤4):
   - machine role: HUD/laptop · node (always-on, firstmate) · fleet worker?
   - install optional harnesses (codex/pi/grok/opencode)? herdr backend?
   - run fleet provisioning too (`ansible-ai/provision-just.yml`, `update.yml`)?
     Then act on the answers. For role=node, also run
     `scripts/herdr-node.sh service install all` and verify with `status`.
5. **Verify.** Re-run `scripts/setup-init.sh`; confirm the summary line reports
   0 required tools missing. `just --list` must render the recipe menu.
6. **Report.** Short table: tool → status → action taken. End with exactly what
   remains for the human (e.g. auth logins), or "nothing".

## Common issues (if you hit EXACTLY these, apply the known fix)

- **Problem:** a tool is installed but reads `missing` (brew/`~/.local/bin` tools).
  **Solution:** non-login shells lack PATH; the scripts already harden PATH — if you
  reproduce it in Bash, prefix `export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"`.
- **Problem:** zsh startup noise pollutes command output / agent panes (pyenv help
  text, gitstatus errors).
  **Solution:** malformed `pyenv init` lines in `~/.zshrc` — the invocation must be
  `eval "$(pyenv init - zsh)"` (a SHELL name, never a home path). Back up before edit.
- **Problem:** crewmate/subagent file reads blocked by a `scout-block` hook error.
  **Solution:** ensure `AR_DISABLE_SCOUT_BLOCK=1` is exported in `~/.zshenv` (covers
  every zsh invocation).
- **Problem:** `Permission denied` writing to `~/Downloads` or similar.
  **Solution:** macOS TCC — tell the user to grant the terminal Files-and-Folders
  access in System Settings; do not retry around it.
- **Problem:** ansible reports a host `UNREACHABLE`.
  **Solution:** the box is offline; skip it and note that `just fleet-just` /
  `update.yml` are idempotent to re-run when it returns.

## Rules

- Never commit, never touch `~/.claude/settings.json` hooks, never store secrets.
- Report failures verbatim from the log — no smoothing over.
