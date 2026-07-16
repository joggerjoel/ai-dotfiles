# Remote Control (`/rc`) troubleshooting

## Symptom

`/remote-control` (or `/rc`) doesn't appear in Claude Code on a machine
provisioned by this repo, even though the account is eligible and the binary
is current.

## Root cause

The desktop profile ships privacy opt-outs in `settings.json`:
`DISABLE_TELEMETRY`, `DO_NOT_TRACK`, and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`. Claude Code gates its
feature-flag reads behind these vars, so **any one of them silently disables
Remote Control** and other flag-gated features.

- Upstream report: [iamnolanhu/claude-dotfiles#4](https://github.com/iamnolanhu/claude-dotfiles/issues/4)
- Claude Code issue: [anthropics/claude-code#76748](https://github.com/anthropics/claude-code/issues/76748)

## Fix (per machine — this does NOT deploy fleet-wide)

The Remote Control choice lives in the machine-local, gitignored
`.local/.remote-control`. Set it to `yes` and re-apply:

```bash
cd ~/ai-dotfiles   # or wherever this repo is checked out
mkdir -p .local
echo yes > .local/.remote-control
./setup.sh update
```

> If `.local/` didn't exist, none of this machine's setup answers were saved
> and every update has been applying **defaults** (desktop profile). Seed the
> rest too: `echo vps > .local/.profile` on a server (plus `.github-user` and
> `.hide-ai`), or re-run `./setup.sh`.

Then **restart Claude Code** — the env vars are read at startup.

With the choice set to `yes`, `setup.sh` installs `~/.claude/settings.json`
as a **copy with the three gate vars stripped** instead of the usual symlink
into `profiles/<profile>/settings.json`. The other telemetry vars
(`DISABLE_ERROR_REPORTING`, `NEXT_TELEMETRY_DISABLED`, etc.) are not part of
the gate and stay off.

Remotely, via the fleet tooling (one host):

```bash
cd ansible-ai
ansible <host> -m shell -a 'cd ~/ai-dotfiles && mkdir -p .local && echo yes > .local/.remote-control && bash setup.sh update'
```

(On the fleet, the repo lives at `~/ai-dotfiles` — that's `dotfiles_dir` from
the inventory; only the control node uses its own checkout path.)

## Why it doesn't deploy to the whole fleet

`.local/` is the personal, per-machine layer — it is gitignored and each host
re-applies its **own** saved answer on every `setup.sh update`. Flipping one
machine changes only that machine. To enable everywhere, run the ansible
one-liner against a group (e.g. `aorus_ai`), accepting the caveats below per
host.

## Caveats

1. **Telemetry trade-off:** stripping the gate vars turns Claude Code
   telemetry back on for that machine. That's the cost of `/rc` until the
   upstream behavior changes.
2. **Symlink → copy:** the live settings become a copy, so profile edits
   reach the machine only via `setup.sh update` (the fleet playbook runs
   this), not instantly through the symlink. Side benefit: the checkout
   stops being dirtied by plugin installs writing through the symlink.
3. **Headless servers:** only worth flipping if you actually run interactive
   `claude` sessions there that you want visible in claude.ai/code.

## Still not showing?

- Restart Claude Code (env is read at startup).
- `claude --version` — Remote Control requires a current binary.
- Verify the gate vars are really gone from the live file:
  `jq -r '.env | keys[]' ~/.claude/settings.json | grep -E 'DISABLE_TELEMETRY|DO_NOT_TRACK|NONESSENTIAL'`
  (want: no output) and that it's a copy, not a symlink:
  `ls -la ~/.claude/settings.json`.
- Check account eligibility on that machine's login.
- Flip back anytime: `echo no > .local/.remote-control && ./setup.sh update`.
