# Machine Context: Local Development Mac

This file specifies the exact local environment and autonomy rules for coding agents running on this machine.

---

## 1. Machine Identification
- **Machine Name**: Local Mac (Primary Workstation)
- **Role**: Master Controller & Local Development
- **Operating System**: macOS (Apple Silicon / Darwin arm64)
- **Primary Shell**: `/bin/zsh`

## 2. Local Runtimes & Toolchains
- **Herdr**: `/opt/homebrew/bin/herdr` (v0.9.0)
- **Python**: Python 3.11 (`/Users/joggerjoel/.pyenv/shims/python3`)
- **Package Managers**: Homebrew (`/opt/homebrew/bin/brew`), uv / pip
- **Multiplexer**: Herdr (primary), tmux (`/opt/homebrew/bin/tmux`)

## 3. Path & Workspace Standards
- **Master Control Workspace**: `/Users/joggerjoel/Developer/herdr/ochestrator`
- **Herdr Config & Socket**: `~/.config/herdr/herdr.sock`

## 4. Autonomy Directives (Standing Permissions)
1. **Full Development Autonomy**: Pre-approved to run standard build commands, package installations, test runners, git status/diff inspections, and file creations.
2. **Do Not Ask for Routine Approvals**: Do not ask the user for confirmation when running tests, creating temporary files, or executing non-destructive scripts.
3. **Strict Verification**: Always verify code changes by executing automated tests (`python3 -m unittest`, `pytest`, etc.) before marking a task complete.
4. **No Premature Halting**: Proceed automatically to subsequent tasks in `TODO.md` unless a fatal blocker occurs.
5. **Safety Gate**: Any irreversible destructive actions (`rm -rf` outside scratch, dropping databases, deleting cloud infrastructure) MUST halt and escalate to human review.
