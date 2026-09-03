# Contributing

Thanks for trying this. It is a personal fleet system that recently became worth
handing to other people, so the most valuable thing you can give back is a
report of what broke on **your** machine — not a patch.

## The fastest useful contribution

```bash
git clone https://github.com/joggerjoel/ai-dotfiles.git
cd ai-dotfiles
./setup.sh
```

Then tell us what happened, even if it worked. "Clean install, macOS 15, no
errors" is a useful data point — the install has been exercised on very few
machines that were not already configured.

If it broke, open a **Cold install failed** issue. Include the OS, the shell,
and the last 30 lines before the failure. That is enough to act on.

## Reporting anything else

Open an issue. There are two templates; pick whichever fits, or neither.

What makes a report actionable here:

- **What you ran** — the exact command, not a description of it
- **What happened** — the output, pasted, not summarized
- **Which machine** — OS, architecture, and whether it is a fresh box
- **`./scripts/preflight.sh`** output if the problem is "something isn't working"

Redact before pasting: `.env`, `ansible-ai/inventory.local.yml`, anything under
`~/.claude/`, hostnames and IPs you would rather not publish. The preflight
output is designed to be safe to share, but read it before you paste it.

## Running the tests

```bash
just test-all        # every suite — the same command CI runs
just test            # preflight suite only
just guard-verify    # injection-guard, including the local backtest
```

330 tests, all passing on `main`, under bash 3.2 and bash 5. If you add a suite,
add it to `scripts/run-all-tests.sh` — that list is what CI runs, and it is the
only place a suite needs registering.

## Sending code

- Branch off `main`, open a PR.
- `just test-all` must pass. CI runs it on Ubuntu and macOS.
- Match the surrounding style. Shell here is defensive on purpose: fail loud,
  never `set -e` where one failure should not stop the rest, and every
  destructive step idempotent.
- Do not hand-edit vendored files. They carry a header naming their source and a
  re-vendor command. See [NOTICE.md](NOTICE.md).
- Commit messages: lowercase `area: what changed`, and say *why* in the body if
  it is not obvious.

## Rough edges you do not need to report

Known, tracked, not news:

- `just auth-login` only implements `cursor`. `codex` and `claude` exit 2 on
  purpose — automating a login prompt from assumption is worse than not
  automating it.
- The non-SSH mesh bridge in `~/Developer/herdr/scripts/herdr-node.sh` is experimental and
  control-plane only. Interactive attach needs SSH, because the TUI passes file
  descriptors and those cannot cross a TCP bridge.
- macOS Local Network permission can silently break SSH from launchd-started
  herdr panes. Documented in the README; it is an OS behaviour, not a bug here.
- The fleet layer assumes hosts you can already SSH into. It does not provision
  machines from nothing.

## Scope

This installs and configures third-party software (`herdr`, `firstmate`,
`9router`, the agent CLIs). Bugs in those belong in their trackers — see
[NOTICE.md](NOTICE.md) for where. Bugs in how *this* installs or wires them
belong here.
