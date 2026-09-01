#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# observability.sh — converge the fleet on the desired state written in
# ansible-ai/observability.yml.
#
#   check     Read-only. Print desired against actual for every host and
#             exit 1 when anything has drifted. Nothing writes. Run this to
#             audit a converge run instead of trusting its summary.
#
# Host state resolves to exactly one of seven outcomes, never to a yes/no:
#   absent        no binary; install
#   behind        older than the manifest; upgrade
#   ahead         newer than the manifest; the manifest is stale, not the host
#   current       no action
#   unreachable   ssh could not connect; no evidence either way
#   authfail      ssh rejected the key; no evidence, and a config problem
#   hostkey       the host key changed; no evidence, and a security signal
#
# The last three are not a pass. An audit that counts silence as success is
# worse than no audit, because it is trusted.
#
# "Already installed" was the original requirement and it is not sufficient.
# All seven ubuntu hosts reported node_exporter as active while sitting three
# minor versions behind upstream, so presence was never the right question.
#
# Flags:
#   --host <name>   Check one host instead of the whole fleet.
#   --manifest <f>  Override the manifest path (used by the tests).
#   --inventory <f> Override the ansible inventory path.
# ─────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(dirname "$SCRIPT_DIR")"

MANIFEST="${OBS_MANIFEST:-$DOTFILES_DIR/ansible-ai/observability.yml}"
INVENTORY="${OBS_INVENTORY:-$DOTFILES_DIR/ansible-ai/inventory.local.yml}"
ONLY_HOST=""

# fleet_hosts() reads the ansible inventory, which is the one roster this repo
# trusts. Deriving the check list from it means a host cannot be monitored
# without also being managed.
# shellcheck source=../lib/fleet.sh
source "$DOTFILES_DIR/lib/fleet.sh"

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'
RED='\033[31m'; RESET='\033[0m'
ok()     { echo -e "  ${GREEN}✓${RESET} $1"; }
warn()   { echo -e "  ${YELLOW}!${RESET} $1"; }
fail()   { echo -e "  ${RED}✗${RESET} $1"; }
header() { echo -e "\n${BOLD}$1${RESET}"; }

SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

# ── Manifest (the boundary) ──────────────────────────────────────
# Every value is read and validated here. Nothing downstream re-checks it.

manifest_get() {
  python3 - "$MANIFEST" "$1" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    node = yaml.safe_load(fh)
for key in sys.argv[2].split('.'):
    node = node.get(key) if isinstance(node, dict) else None
    if node is None:
        sys.exit(f"observability.yml: missing key {sys.argv[2]}")
print(node)
PY
}

# Reports rather than exits, so a caller that sources this file (the tests) is
# not killed by a bad manifest path.
manifest_validate() {
  if [ ! -r "$MANIFEST" ]; then
    fail "manifest not readable: $MANIFEST"
    return 2
  fi
  local key
  for key in node_exporter.version stack.dir; do
    manifest_get "$key" >/dev/null || return 2
  done
}

# ── Version reconciler (pure) ────────────────────────────────────
# Takes two version strings, returns one state token. No I/O, so the tests
# drive it with recorded strings instead of a live fleet.

reconcile_version() {
  local actual="$1" desired="$2"
  # Non-version probe results pass straight through. authfail and hostkey are
  # kept distinct from unreachable because they mean different things: a
  # sleeping laptop is routine, a changed host key is a security signal, and
  # collapsing both into one token hides the second behind the first.
  case "$actual" in
    unreachable|authfail|hostkey) echo "$actual"; return ;;
    absent)                       echo absent;    return ;;
  esac
  if [ "$actual" = "$desired" ]; then
    echo current
  elif [ "$(printf '%s\n%s\n' "$actual" "$desired" | sort -V | head -1)" = "$actual" ]; then
    echo behind
  else
    echo ahead
  fi
}

# ── Probes ───────────────────────────────────────────────────────

# Prints the installed node_exporter version, or the token `absent`. Callers
# distinguish an unreachable host before calling this.
# Resolved by absolute path as well as by PATH. ssh runs a non-login shell whose
# PATH often omits /usr/local/bin, so `command -v` alone reported macstudio as
# absent while node_exporter was running there as root out of /usr/local/bin.
# That is the same failure agents-update.sh already carries resolve_tool for.
# "Not on PATH" is not "not installed", and reporting it as absent would have
# reinstalled over a working host.
probe_cmd='
for c in node_exporter /usr/local/bin/node_exporter /opt/homebrew/bin/node_exporter "$HOME/.local/bin/node_exporter"; do
  p="$(command -v "$c" 2>/dev/null)" || p=""
  [ -n "$p" ] || { [ -x "$c" ] && p="$c"; }
  if [ -n "$p" ]; then
    v="$("$p" --version 2>&1 | head -1 | awk "{print \$3}")"
    [ -n "$v" ] && { printf "%s" "$v"; exit 0; }
  fi
done
printf absent
'

probe_host() {
  local host="$1" out err rc
  if [ "$host" = "localhost" ]; then
    out="$(bash -c "$probe_cmd" 2>/dev/null)" || out="absent"
    [ -n "$out" ] || out="absent"
    echo "$out"
    return
  fi

  err="$(mktemp)"
  out="$(ssh "${SSH_OPTS[@]}" "$host" "$probe_cmd" 2>"$err")" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    # ssh returns 255 for every connection-layer failure, so the reason is only
    # in stderr. A rejected key and a changed host key both used to read as
    # "unreachable", which made a swapped host key indistinguishable from a
    # laptop asleep.
    if grep -qiE 'REMOTE HOST IDENTIFICATION|host key verification' "$err"; then
      rm -f "$err"; echo hostkey; return
    fi
    if grep -qi 'permission denied' "$err"; then
      rm -f "$err"; echo authfail; return
    fi
    rm -f "$err"; echo unreachable; return
  fi
  rm -f "$err"
  [ -n "$out" ] || out="absent"
  echo "$out"
}

# ── check ────────────────────────────────────────────────────────

cmd_check() {
  manifest_validate || return 2
  local desired; desired="$(manifest_get node_exporter.version)"

  local hosts
  if [ -n "$ONLY_HOST" ]; then
    hosts="$ONLY_HOST"
  else
    # localhost is the control node. It is a laptop that sleeps and leaves the
    # LAN, so it is listed but never counted as fleet health.
    hosts="$(fleet_hosts "$INVENTORY") localhost"
  fi

  header "node_exporter (desired $desired)"
  printf "  %-12s %-12s %s\n" HOST INSTALLED STATE
  printf "  %-12s %-12s %s\n" "────────────" "────────────" "─────"

  # blind counts hosts that produced no evidence either way. It is tracked
  # separately from drift because it is not the same claim: drift says a host
  # is wrong, blind says we do not know. Folding blind into a pass is how an
  # audit tool reports success for a fleet that is entirely down.
  local drift=0 blind=0 host actual state
  for host in $hosts; do
    actual="$(probe_host "$host")"
    state="$(reconcile_version "$actual" "$desired")"
    case "$state" in
      current)
        printf "  %-12s %-12s ${GREEN}%s${RESET}\n" "$host" "$actual" "$state" ;;
      hostkey|authfail)
        printf "  %-12s %-12s ${RED}%s${RESET}\n" "$host" "-" "$state"
        blind=$((blind + 1)) ;;
      unreachable)
        printf "  %-12s %-12s ${YELLOW}%s${RESET}\n" "$host" "-" "$state"
        blind=$((blind + 1)) ;;
      *)
        printf "  %-12s %-12s ${YELLOW}%s${RESET}\n" "$host" "$actual" "$state"
        drift=$((drift + 1)) ;;
    esac
  done

  echo
  [ "$drift" -eq 0 ] || warn "$drift hosts differ from the manifest. Run 'converge' to fix them."
  [ "$blind" -eq 0 ] || fail "$blind hosts gave no answer. This is not a pass."
  if [ "$drift" -eq 0 ] && [ "$blind" -eq 0 ]; then
    ok "every host answered and matches the manifest"
    return 0
  fi
  return 1
}

usage() {
  echo "Usage: observability.sh check [--host <name>] [--manifest <f>] [--inventory <f>]"
}

# ── Main ─────────────────────────────────────────────────────────
# Guarded so the tests can source this file and drive reconcile_version
# directly, without a live fleet and without argument parsing running.

main() {
  local cmd="${1:-}"; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --host)      ONLY_HOST="${2:-}"; shift 2 ;;
      --manifest)  MANIFEST="${2:-}";  shift 2 ;;
      --inventory) INVENTORY="${2:-}"; shift 2 ;;
      *) usage; exit 2 ;;
    esac
  done

  case "$cmd" in
    check) cmd_check ;;
    *)     usage; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
