#!/usr/bin/env bash
# claude-token.sh — put the fleet's Claude credential in place, in one command.
#
#   just claude-token            # set it if needed, then deploy to the fleet
#   just claude-token aorus4     # ...to one host
#   just claude-token --check    # dry run: prove the token works, write nothing
#
# Why this exists rather than a documented sequence of steps: the documented
# sequence had a hole. `read -rs TOKEN` in one shell and `printf ... "$TOKEN"`
# in another writes `CLAUDE_CODE_OAUTH_TOKEN=` with an empty value — a line that
# passes every "is the token set?" grep and authenticates nothing. This script
# reads and writes the value in the SAME process, and refuses an empty one.
#
# SECURITY: the value is never echoed, never in argv, never in shell history,
# and never printed by any command here. It is read with `read -rs`, held in a
# variable, and written to a 0600 file.

set -uo pipefail
set -f

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

ENV_FILE="${HERDR_CLAUDE_ENV:-$HOME/.claude/.env}"
PLAYBOOK="$ROOT/ansible-ai/deploy-claude-token.yml"
REAL_INVENTORY="$ROOT/ansible-ai/inventory.local.yml"
HOSTS_DEFAULT="aorus aorus4 aorus5 aorus6 aorus7 aorus8"

die() { printf '%s\n' "$*" >&2; exit 1; }

# The value of CLAUDE_CODE_OAUTH_TOKEN in $ENV_FILE, or empty. Deliberately
# returns the VALUE and not a yes/no: "the key is present" is exactly the
# question whose wrong answer caused this script to exist.
#
# awk, and no `\t`/`\r` escapes anywhere. This was a sed one-liner until a real
# token exposed the bug: BSD sed (macOS) does not interpret `\t` or `\r` inside
# a bracket expression, so `[^"'\r]` excluded the LITERAL characters `\` and
# `r`, and `[ \t]` matched `t`. A 108-character token containing an `r` parsed
# as empty. The unit tests all passed because the fake value they used —
# `sk-ant-oat-FAKE-000` — happens to contain no `r`.
#
# Split on the first `=` and trim by hand instead: no character classes to get
# wrong, and identical behaviour on BSD and GNU awk. `\047` is an apostrophe,
# written octal so this survives the surrounding shell quoting.
token_from_env_file() {
  [ -r "$ENV_FILE" ] || return 0
  awk '
    /^[[:blank:]]*(export[[:blank:]]+)?CLAUDE_CODE_OAUTH_TOKEN[[:blank:]]*=/ {
      v = substr($0, index($0, "=") + 1)
      gsub(/\r/, "", v)
      sub(/^[[:blank:]]+/, "", v); sub(/[[:blank:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      sub(/^[[:blank:]]+/, "", v); sub(/[[:blank:]]+$/, "", v)
      # Later wins: this file is appended to, so a real value must override an
      # earlier broken one rather than the scan stopping at the first match.
      if (length(v) > 0) last = v
    }
    END { if (length(last) > 0) print last }
  ' "$ENV_FILE"
}

# Does this token actually authenticate? Set in the environment on purpose:
# CLAUDE_CODE_OAUTH_TOKEN overrides a stored credential (verified on aorus8),
# so this tests the token rather than this machine's own login.
token_authenticates() {
  CLAUDE_CODE_OAUTH_TOKEN="$1" claude -p 'reply with just ok' >/dev/null 2>&1
}

prompt_for_token() {
  local tok=""
  [ -t 0 ] || die "no terminal to read from — run this from an interactive shell"
  printf 'Mint one with: claude setup-token\n' >&2
  printf 'Paste the token (input hidden), then Enter: ' >&2
  # Read and use in the SAME process. This is the whole point.
  IFS= read -rs tok < /dev/tty
  printf '\n' >&2
  # Strip whitespace a paste can bring along; reject what is left if empty.
  tok="$(printf '%s' "$tok" | tr -d '\r\n' | sed -E 's/^[ \t]+//; s/[ \t]+$//')"
  [ -n "$tok" ] || die "empty token — nothing written"
  printf '%s' "$tok"
}

ensure_token() {
  local tok
  tok="$(token_from_env_file)"
  if [ -n "$tok" ]; then
    printf 'token found in %s\n' "$ENV_FILE" >&2
  else
    printf 'no usable CLAUDE_CODE_OAUTH_TOKEN in %s\n' "$ENV_FILE" >&2
    tok="$(prompt_for_token)" || exit 1
  fi

  # Validate BEFORE storing. A token that does not authenticate is worse than
  # none: it overrides working credentials on every host it reaches.
  printf 'checking the token authenticates... ' >&2
  if token_authenticates "$tok"; then
    printf 'ok\n' >&2
  else
    die "that token does not authenticate — nothing written. Mint a fresh one with: claude setup-token"
  fi

  # Store only if it was not already there.
  if [ -z "$(token_from_env_file)" ]; then
    mkdir -p "$(dirname "$ENV_FILE")"
    touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
    printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$tok" >> "$ENV_FILE"
    printf 'stored in %s (0600)\n' "$ENV_FILE" >&2
  fi
  CLAUDE_TOKEN_VALUE="$tok"
}

# Prefer the shared inventory when it exists. Otherwise build a throwaway one
# from ssh aliases: ansible goes through ssh, so ~/.ssh/config resolves the
# hosts and no IPs, usernames, or jump hosts are written down. A half-filled
# inventory.local.yml would quietly misconfigure every OTHER playbook, so this
# never creates one.
# The ansible flags for a given check value, and the single place that decision
# is made. It was inline as `${check:+--check --diff}`, which expands whenever
# the variable is NON-EMPTY — and "0" is non-empty, so --check went on every
# run. Ansible then printed `changed:` for three tasks, showed a diff, reported
# no failures, and wrote nothing: a dry run wearing a deploy's clothes.
ansible_flags() {
  [ "${1:-0}" = 1 ] && printf '%s' "--check --diff"
  return 0
}

inventory_for() {
  local hosts="$1" tmpd tmp h
  if [ -r "$REAL_INVENTORY" ]; then
    printf '%s' "$REAL_INVENTORY"
    return 0
  fi
  # A DIRECTORY, so the file inside can be named `inventory.yml`. ansible picks
  # its parser from the FILENAME: `mktemp -t claude-token-inv` yields a random
  # suffix and no extension, so ansible tried its INI plugin on YAML and
  # reported `Invalid host pattern 'aorus_ai:'` — an error about the content
  # that was really about the name.
  tmpd="$(mktemp -d -t claude-token-inv)" || die "could not create a temp inventory"
  tmp="$tmpd/inventory.yml"
  {
    printf 'aorus_ai:\n  hosts:\n'
    for h in $hosts; do printf '    %s: {}\n' "$h"; done
    printf '  vars:\n    ansible_ssh_common_args: "-o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"\n'
  } > "$tmp"
  printf '%s' "$tmp"
}

main() {
  local check=0 hosts="" inv limit rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check=1; shift ;;
      -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
      -*) die "unknown flag: $1" ;;
      *) hosts="$hosts $1"; shift ;;
    esac
  done
  hosts="${hosts# }"
  [ -n "$hosts" ] || hosts="$HOSTS_DEFAULT"

  command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook not found"
  [ -r "$PLAYBOOK" ] || die "playbook not found: $PLAYBOOK"

  ensure_token

  inv="$(inventory_for "$hosts")"
  limit="$(printf '%s' "$hosts" | tr ' ' ',')"

  printf '\ndeploying to: %s%s\n\n' "$limit" "$([ "$check" = 1 ] && printf ' (dry run)')" >&2
  # The token reaches ansible through the environment, by name — never on the
  # command line, where `ps` would show it to every user on this machine.
  #
  # Spelled out rather than `${check:+--check --diff}`. That form tests for a
  # NON-EMPTY value, and "0" is non-empty — so --check was passed on every run,
  # including the ones meant to write. Ansible then reported `changed:` for
  # three tasks and wrote nothing, which reads exactly like a successful deploy.
  if [ "$(ansible_flags "$check")" = "--check --diff" ]; then
    CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_TOKEN_VALUE" \
      ansible-playbook -i "$inv" "$PLAYBOOK" --limit "$limit" --check --diff
  else
    CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_TOKEN_VALUE" \
      ansible-playbook -i "$inv" "$PLAYBOOK" --limit "$limit"
  fi
  rc=$?

  # Remove the whole temp DIRECTORY, not just the file inside it.
  case "$inv" in */claude-token-inv*/inventory.yml) rm -rf "$(dirname "$inv")" ;; esac

  if [ "$rc" -eq 0 ] && [ "$check" = 0 ]; then
    printf '\nverify with:  just auth-status\n' >&2
    printf 'hosts on the fleet token report `token` rather than `authed`.\n' >&2
  fi
  return "$rc"
}

case "${1:-}" in
  _token_from_env_file) shift; token_from_env_file ;;
  # Prints the path to a generated inventory. The caller owns cleanup; used by
  # the tests to hand a real file to `ansible-inventory` and prove it parses.
  _inventory_for) shift; inventory_for "$*" ;;
  # Prints the ansible flags a given check value produces. Exists so a test can
  # assert that check=0 yields NOTHING: `${check:+...}` expanded on "0" because
  # that string is non-empty, so every run was a dry run and no deploy could
  # ever have written anything.
  _ansible_flags) shift; ansible_flags "${1:-0}" ;;
  *) main "$@" ;;
esac
