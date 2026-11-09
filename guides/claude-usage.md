# Ask whether a Claude login is usage-limited with claude-usage

`claude-usage` asks Anthropic's usage endpoint whether one Claude subscription
login is out of quota and when it resets. A job can then skip with "limited
until 6:59 pm" instead of failing mid-run. It makes no model call and costs no
tokens.

## Install

`./setup.sh` (or `./update.sh`) links `bin/claude-usage` to
`~/.local/bin/claude-usage` through `link_bin_tools`, like every other `bin/`
tool. It needs only `python3` (3.8 or later, standard library).

## Use

```sh
claude-usage                                   # the ambient login (~/.claude)
claude-usage --config-dir ~/.claude-accounts/joel_labelle
claude-usage --json
```

```text
joel.labelle@gmail.com (max): LIMITED until Mon Nov 09 19:00 EST
  weekly_all                 100%  critical  resets Mon Nov 09 19:00 EST
```

The text form lists the active or notable limits (active, at least 50%, or
critical). `--json` prints one stable shape:

```json
{"account": "joel.labelle@gmail.com", "subscription": "max", "limited": true,
 "resets_at": "2026-11-09T23:59:59Z",
 "limits": [{"kind": "weekly_all", "group": "weekly", "scope": null,
             "percent": 100.0, "severity": "critical",
             "resets_at": "2026-11-09T23:59:59Z", "active": true}]}
```

`limited` is true when any limit is at 100% or critical. `resets_at` is the
latest reset among those limits, because the login is usable again only when
all of them have cleared. A limit with a `scope` (a single model, such as
Fable) blocks only that model, so a consumer that needs one model can read
`limits` instead of `limited`. On exit 3 or 4 the JSON has `limited: null` and
an `error` code, and the reason is on stderr.

### Exit codes

| Code | Meaning |
| ---- | ------- |
| 0 | Usable. |
| 2 | Limited. `resets_at` says until when. |
| 3 | Cannot tell: `no_login`, `missing_scope`, `http_error`, `network_error` or `bad_response`. |
| 4 | Cannot tell because the access token is expired or was rejected (`stale_token`, `unauthorized`). |

A caller that only needs "may I run?" treats 0 as yes and everything else as
no, and reads 2 for the reset time.

## The scope requirement

The endpoint needs the `user:profile` OAuth scope. The token from
`claude setup-token` (the fleet's `CLAUDE_CODE_OAUTH_TOKEN`) has only
`user:inference`, and the endpoint answers it with HTTP 403
`oauth_scope_insufficient`. So `claude-usage` ignores `CLAUDE_CODE_OAUTH_TOKEN`
and reads the interactive login that `claude auth login` stores. Each
subscription account therefore needs one interactive login on the machine that
asks.

## Add a second account's login

Give each account its own config dir and log in with that dir:

```sh
CLAUDE_CONFIG_DIR=~/.claude-accounts/<name> claude auth login
claude-usage --config-dir ~/.claude-accounts/<name>
```

## Where the login lives

| Platform | Location |
| -------- | -------- |
| Linux | `$CLAUDE_CONFIG_DIR/.credentials.json` (default `~/.claude/.credentials.json`) |
| macOS, default config dir | Keychain generic password, service `Claude Code-credentials` |
| macOS, `CLAUDE_CONFIG_DIR` set | Keychain service `Claude Code-credentials-` plus the first 8 hex digits of the SHA-256 of the config dir path |

The path is hashed as given: absolute, no trailing slash, NFC-normalised.
`claude-usage` derives the name itself, tries the symlink-resolved path as
well, and falls back to the `.credentials.json` file. Measured on Claude Code
2.1.319: `/Users/joggerjoel/.claude-accounts/joel_labelle` maps to
`Claude Code-credentials-22e0b5a1`. Pass `--keychain-service NAME` to override
the derivation if a later Claude Code changes it. Pair it with `--config-dir`
so the account email comes from the same login.

## Stale tokens

Access tokens last hours. Claude Code refreshes them when it runs, and
`claude-usage` does not: it never calls an OAuth refresh endpoint and never
makes an inference call. An expired token gives exit 4. Run any `claude`
command with that config dir, then ask again.

Checked on Claude Code 2.1.319: `claude auth status --json` (which
`claude-usage` runs first for the account email) left the stored credential
byte-identical when the token had hours left. Whether it refreshes a token at
the expiry edge was not tested, because forcing it means refreshing a copy of
a real login, which rotates the refresh token. Treat exit 4 as "refresh first".

## Tests

`just test-all` runs `scripts/claude-usage.test.sh`: a fake usage endpoint, a
fake `security` and `claude` on `PATH`, and a scratch `HOME`.
