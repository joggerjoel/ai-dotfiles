#!/bin/bash
# Fleet host registry shared by herdr-auth.sh and claude-token.sh.
# Sourced, never executed. Defines data and one pure function; no side effects.

# The ansible group that IS the fleet. Everything in it is a managed host.
FLEET_GROUP="aorus_ai"

# Consulted only where inventory.local.yml is absent. That file is gitignored
# because this repo is public, so a worker checkout has no fleet list of its
# own and still needs one to answer --help or run a single named host.
FLEET_HOSTS_FALLBACK="aorus aorus2 aorus4 aorus5 aorus6 aorus7 aorus8"

# The fleet, space separated, read from the inventory group when that file is
# readable. The inventory is what ansible actually deploys against, so a second
# list written down beside it is a copy that drifts: aorus2 joined the group and
# stayed missing from both scripts, which silently skipped a managed host for
# auth probing and token distribution alike.
fleet_hosts() {
  local inv="${1:-}"
  if [ ! -r "$inv" ]; then
    printf '%s' "$FLEET_HOSTS_FALLBACK"
    return 0
  fi
  awk -v group="${FLEET_GROUP}:" '
    # A group ends at the next column-0 key, so membership is scoped without
    # needing a YAML parser for a file this shape.
    /^[^[:space:]]/     { in_group = ($0 == group); in_hosts = 0 }
    in_group && /^  hosts:[[:space:]]*$/ { in_hosts = 1; next }
    in_group && /^  [^[:space:]]/        { in_hosts = 0 }
    in_hosts && /^    [A-Za-z0-9_.-]+:/ {
      name = $1; sub(/:$/, "", name)
      printf "%s%s", (found++ ? " " : ""), name
    }
  ' "$inv"
}
