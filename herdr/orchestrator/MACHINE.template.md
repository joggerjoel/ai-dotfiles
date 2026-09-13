# Machine Context & Autonomy Rules

Copy this to each machine and fill in the placeholders. Two copies exist (plan §2.1): the
repo-tracked one is injected into agents, and the supervisor-owned one at
`~/.herdr-master/machines/<profile>/MACHINE.md` supplies every value the supervisor acts on.

**This file is a schema, not prose.** `herdr_master/config.py` parses it, and
`test_config.py` asserts that this template parses. Keep the `- **Key**: value` and
``- `key`: value`` shapes; a reworded key is an unreadable config. Every absence has a
defined consequence, listed against each field below, rather than a silent default.

- **Machine ID**: your-hostname
- **Profile**: local # a §7 registered profile, or `local`
- **Timezone**: America/Toronto # absent -> rate-limit events escalate (§9.3)
- **Working Directory**: ~/projects/your-repo
- **Base Branch**: main # absent -> TODO-lane dispatch escalates
- **Worktree Root**: ~/projects/.worktrees
- **Runtime**: Python 3.13 (uv), Node 22 (bun), Docker # informational, for the agent
- **Panes**: # §7 bootstrap creates any that are absent
  - `worker_pane`: your-repo-worker
  - `verify_pane`: your-repo-verify
  - `shell_pane`: your-repo-shell # non-agent pane for git and file work (§2.3)
- **Verification**:
  - `lint_cmd`: `ruff check .`
  - `test_cmd`: `python3 -m unittest discover -q` # absent -> the unit escalates, never passes
  - `test_timeout_ms`: 600000 # absent -> 600000; unratified, see §11.2
  - `stall_idle_seconds`: 900 # absent -> 900
- **Agent kinds & exhaustion patterns** (§10.2; unlisted kind -> escalate):
  - `claude`: `/context (left until |low|exhausted)|running out of context/i`
    # deliberately NOT a bare /compact/: "auto-compact" appears in routine status
    # output, and matching it would end an attempt on ordinary text
- **Dependency policy** (advisory to the agent; enforced at land time in §4):
  - `allowed_registries`: [`pypi.org`]
  - `allowed_installers`: [`uv add`]
- **Rules**:
  1. Use the runtime's native package manager only; never a second one.
  2. Never ask permission for standard development actions. Installing a dependency that
     satisfies the policy above, running builds, running tests, creating files, and
     formatting code are all pre-approved.
  3. Anything outside the dependency policy: stop and ask.
  4. Never ask "Should I run tests?" or "Should I proceed to the next task?". Always run
     tests before declaring work done, and always proceed.
  5. Where two implementations are equally valid, match the existing project patterns
     rather than pausing for human input.
  6. Follow the repo's existing directory structure.
  7. Signal completion by printing `MC-DONE` followed by a space and the nonce supplied
     with the task, and nothing after it. The literal lives here and in the supervisor.
     A prompt supplies only the nonce and never the pair, because the supervisor matches
     on `MC-DONE <nonce>` and a prompt containing that pair could satisfy the match with
     its own echo (§2.3). An echo of this file cannot, since it carries no nonce.

The git and PR token backend is deliberately absent from this file. The daemon reads it, the
daemon runs on the orchestrator, and it has no access to a remote machine's keychain. Chrome
and browser settings are absent for the same reason: Chrome runs only on the orchestrator, so
those live in the orchestrator's own config (§9.2) rather than in every machine's file.
