# Run fleet Claude jobs on two subscriptions

A cron job that calls `claude -p` stops when its account hits the usage limit.
`bin/claude-acct` runs `claude` on the first account that still has quota,
moves to the next when one runs out, and goes back after the reset. It uses
subscription tokens from `claude setup-token` only, never metered API keys.

## How it works

Each account has a one-year token, stored as `CLAUDE_CODE_OAUTH_TOKEN_<NAME>`
(the name upper-cased). `CLAUDE_ACCOUNTS="first second"` lists the names in
preference order. `just claude-token` writes all of them to
`~/.config/claude-fleet/env` on every `aorus_ai` host, and exports the first
account's token as plain `CLAUDE_CODE_OAUTH_TOKEN`, so a bare `claude` keeps
working.

`claude-acct` sources that file itself, because cron does not run a login
shell. When `claude` exits non-zero and prints its limit message, for example

```
You've hit your limit · resets 1am (Europe/Oslo)
```

it records the account as exhausted until that time in
`${XDG_STATE_HOME:-~/.local/state}/claude-acct/<name>` (1 hour when the time
cannot be read) and retries with the next account. A revoked token is skipped
the same way and reported on stderr. If every account fails, the first failure
comes back unchanged, exit status included.

`claude-acct --acct-status` shows each account and when it frees up. It never
prints a token.

Output arrives at the end of the run rather than streaming, because a
discarded attempt must not reach the caller. In a terminal, `claude-acct` just
picks an account and starts `claude`, with no retry.

## Add the second account

The account already on the fleet has no name yet. Name it first so it stays
the primary. This reuses the token already in `~/.claude/.env`, with no new
login:

```sh
just claude-token --account hyunseokkim986 --from-primary
```

Mint the second account's token while logged in as that account, then store
and deploy it. The command prompts for the token without echoing it, proves it
authenticates, writes it to `~/.claude/.env` (0600) and deploys:

```sh
claude setup-token
just claude-token --account joel_labelle
```

Names are lower-case letters, digits and `_`. Add hosts after the flags to
limit the deploy, as in `just claude-token --account joel_labelle aorus8`.
`just claude-token-check` dry-runs a deploy.

Every named token is tested with a real `claude -p` call on the control node
before anything is written, so an account that is out of quota at that moment
fails the check. Run it again after the reset.

## Switch cron lines

Replace `claude` with `claude-acct` and keep every argument:

```
0 * * * * /home/<user>/.local/bin/claude-acct -p "..." --output-format json
```

`./setup.sh` and `./update.sh` link `bin/claude-acct` into `~/.local/bin`. Cron's
`PATH` does not include it, so call it by absolute path. `claude-acct` finds
`claude` on `PATH` or in `~/.local/bin/claude`.

## Limits to know

- Only a non-zero exit with the limit wording counts. A rate-limit `429` that
  Claude Code retries and reports differently is not treated as exhaustion.
- A new wording from Claude Code is not recognised until the patterns at the
  top of `bin/claude-acct` learn it. The failure then passes through unchanged
  and the account is not marked.
- Both accounts at their limit means the job fails with the first account's
  error. The next run tries the account that frees up first.

Tests: `just claude-acct-test`, `just claude-token-test`, also run by
`just test-all`.

## A host's own login as an account

An account can be an interactive `claude auth login` instead of a token. Set
`CLAUDE_CONFIG_DIR_<NAME>` to the config directory that holds the login and
leave its token unset. Ansible owns `~/.config/claude-fleet/env`, so put
per-host settings in `~/.config/claude-acct/env`, which `claude-acct` reads
after the fleet file:

```sh
# ~/.config/claude-acct/env on aorus8: the fleet token first, this host's own
# login (joel.labelle) when that account is limited.
CLAUDE_ACCOUNTS="hyunseokkim986 joel_labelle"
CLAUDE_CODE_OAUTH_TOKEN_HYUNSEOKKIM986="$CLAUDE_CODE_OAUTH_TOKEN"
CLAUDE_CONFIG_DIR_JOEL_LABELLE="$HOME/.claude"
```

The default `~/.claude` stays implicit when the account runs, because on macOS
an explicit `CLAUDE_CONFIG_DIR` names a different keychain entry.
`claude-usage --config-dir <dir>` reads the same login's limits.
