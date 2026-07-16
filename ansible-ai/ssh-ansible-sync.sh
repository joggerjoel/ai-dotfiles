#!/usr/bin/env bash
# ssh-ansible-sync.sh
# Sync hosts from ~/.ssh/config into ansible-ai/inventory.local.yml.
#
# Presents an interactive checklist of the servers found in ~/.ssh/config.
# Hosts ALREADY in inventory.local.yml start [x] (checked); the rest start [ ].
# Toggle with numbers, confirm, and the inventory's `hosts:` block is rewritten
# from your selection. The group `vars:` block (user, ProxyJump, dotfiles vars)
# is preserved untouched.
#
# Excluded automatically: wildcard `Host *` and the derived `*-claude` aliases.
#
# Run with NO arguments for the interactive menu; use an action flag
# (--write / --plan / --deploy) to run non-interactively. See --help.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/config}"
INVENTORY="${INVENTORY:-$SCRIPT_DIR/inventory.local.yml}"
UPDATE_PLAYBOOK="${UPDATE_PLAYBOOK:-$SCRIPT_DIR/update.yml}"
PROVISION_PLAYBOOK="${PROVISION_PLAYBOOK:-$SCRIPT_DIR/provision-ai.yml}"

usage() {
  cat <<'EOF'
ssh-ansible-sync.sh — sync ~/.ssh/config hosts into inventory.local.yml, and
plan/deploy playbooks against them.

  No arguments        open the interactive checklist menu
  action flag         run non-interactively (scripts/CI)

Actions (choose one; omit for the menu):
  --write             write the selection into inventory.local.yml
  --plan              ansible-playbook --check --diff against the selected hosts
  --deploy            real ansible-playbook run against the selected hosts

Options:
  --playbook update|provision  playbook for --plan/--deploy (default: update)
  --hosts a,b,c                target these hosts (default: hosts already in inventory)
  --all                        target every host found in ~/.ssh/config
  --yes, -y                    skip confirmations (deploy); with no action = write-and-exit
  --dry-run                    show the resulting hosts block, write nothing
  -h, --help

Examples:
  ssh-ansible-sync.sh                                          # interactive menu
  ssh-ansible-sync.sh --plan --hosts aorus
  ssh-ansible-sync.sh --deploy --playbook provision --hosts aorus,aorus4 --yes
  ssh-ansible-sync.sh --write --all
EOF
}

DRY_RUN=false
ASSUME_YES=false
ACTION=""           # ""|write|plan|deploy  (non-empty => non-interactive)
PLAYBOOK_CHOICE=""  # ""|update|provision|<path>
HOSTS_CSV=""        # explicit comma-separated host selection
SELECT_ALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --yes | -y) ASSUME_YES=true ;;
    --write) ACTION="write" ;;
    --plan) ACTION="plan" ;;
    --deploy) ACTION="deploy" ;;
    --playbook) [[ $# -ge 2 ]] || { echo "--playbook needs a value" >&2; exit 2; }; PLAYBOOK_CHOICE="$2"; shift ;;
    --playbook=*) PLAYBOOK_CHOICE="${1#*=}" ;;
    --hosts) [[ $# -ge 2 ]] || { echo "--hosts needs a value" >&2; exit 2; }; HOSTS_CSV="$2"; shift ;;
    --hosts=*) HOSTS_CSV="${1#*=}" ;;
    --all) SELECT_ALL=true ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

# Validate the --playbook choice early (update|provision keyword, or a real file).
case "$PLAYBOOK_CHOICE" in
  "" | update | provision) : ;;
  *) [[ -f "$PLAYBOOK_CHOICE" ]] || { echo "Unknown --playbook '$PLAYBOOK_CHOICE' (use update|provision or a file path)" >&2; exit 2; } ;;
esac

[[ -f "$SSH_CONFIG" ]] || { echo "No ssh config at $SSH_CONFIG" >&2; exit 1; }
[[ -f "$INVENTORY" ]] || { echo "No inventory at $INVENTORY" >&2; exit 1; }
grep -qE '^  hosts:' "$INVENTORY" || { echo "inventory.local.yml has no '  hosts:' line" >&2; exit 1; }
grep -qE '^  vars:'  "$INVENTORY" || { echo "inventory.local.yml has no '  vars:' line" >&2; exit 1; }

# Group defaults (used to decide when a per-host override is worth writing).
DEFAULT_USER="$(awk '/^  vars:/{v=1} v && /ansible_user:/{print $2; exit}' "$INVENTORY")"
GROUP_JUMP="$(grep -oE 'ProxyJump=[^ ]+' "$INVENTORY" | head -1 | cut -d= -f2)"

# ── 1. Parse ~/.ssh/config -> name|hostname|user|proxyjump ────────────────────
# awk splits on whitespace regardless of indentation; keywords are case-insensitive.
mapfile -t PARSED < <(awk '
  function flush(){ if(name!=""){ print name"|"hn"|"user"|"pj } }
  { key=tolower($1) }
  key=="host"      { flush(); name=$2; hn=""; user=""; pj="" }
  key=="hostname"  { hn=$2 }
  key=="user"      { user=$2 }
  key=="proxyjump" { pj=$2 }
  END{ flush() }
' "$SSH_CONFIG")

# ── 2. Existing inventory hosts (between `hosts:` and `vars:`) -> checked set ──
declare -A EXISTING=()
while IFS= read -r h; do
  [[ -n "$h" ]] && EXISTING["$h"]=1
done < <(sed -n '/^  hosts:/,/^  vars:/p' "$INVENTORY" \
           | grep -oE '^    [A-Za-z0-9_.-]+:' | tr -d ' :')

# ── Build parallel arrays, filtering wildcards + *-claude aliases ─────────────
NAMES=(); IPS=(); USERS=(); JUMPS=(); CHECK=()
for row in "${PARSED[@]}"; do
  IFS='|' read -r name hn user pj <<<"$row"
  [[ "$name" == *"*"* ]] && continue
  [[ "$name" == *-claude ]] && continue
  NAMES+=("$name")
  IPS+=("${hn:-$name}")
  USERS+=("$user")
  JUMPS+=("$pj")
  # Pre-check if this host already lives in the inventory.
  if [[ -n "${EXISTING[$name]:-}" ]]; then CHECK+=(1); else CHECK+=(0); fi
done

[[ ${#NAMES[@]} -gt 0 ]] || { echo "No selectable hosts in $SSH_CONFIG" >&2; exit 1; }

# ── Flag-driven selection: --all / --hosts override the inventory pre-check ────
# (also pre-selects the menu when no action flag is given).
if $SELECT_ALL; then
  for i in "${!CHECK[@]}"; do CHECK[$i]=1; done
elif [[ -n "$HOSTS_CSV" ]]; then
  for i in "${!CHECK[@]}"; do CHECK[$i]=0; done
  IFS=',' read -ra WANT <<<"$HOSTS_CSV"
  for w in "${WANT[@]}"; do
    w="${w// /}"; [[ -z "$w" ]] && continue
    found=false
    for i in "${!NAMES[@]}"; do
      [[ "${NAMES[$i]}" == "$w" ]] && { CHECK[$i]=1; found=true; break; }
    done
    $found || echo "  ! host not in ~/.ssh/config (ignored): $w" >&2
  done
fi

# ── 3. Interactive checklist ─────────────────────────────────────────────────
# Arrow-key TUI when stdin+stdout are a terminal; line-based fallback otherwise.
TUI=false
[[ -t 0 && -t 1 ]] && TUI=true

# render() emits a FIXED line count so the TUI can redraw in place (no scroll).
MENU_LINES=$(( ${#NAMES[@]} + 5 ))

render() {
  local cursor="$1" goto="$2" clr=""
  $TUI && clr=$'\033[K'          # clear-to-EOL so shrinking lines leave no cruft
  echo
  printf "  Sync ~/.ssh/config -> inventory.local.yml   ([x] = will be in inventory)%s\n" "$clr"
  printf "  ----------------------------------------------------------------%s\n" "$clr"
  for i in "${!NAMES[@]}"; do
    local box="[ ]"; [[ ${CHECK[$i]} -eq 1 ]] && box="[x]"
    local tag=""; [[ -n "${EXISTING[${NAMES[$i]}]:-}" ]] && tag=" (in inventory)"
    local mark=" "; [[ $i -eq $cursor ]] && mark=">"
    printf "  %s %2d) %s %-12s %-16s%s%s\n" \
      "$mark" "$((i + 1))" "$box" "${NAMES[$i]}" "${IPS[$i]}" "$tag" "$clr"
  done
  printf "  ----------------------------------------------------------------%s\n" "$clr"
  if $TUI; then
    if [[ -n "$goto" ]]; then
      printf "  \342\206\221/\342\206\223 move  space toggle  a/n all/none  enter done  q quit   [go to #: %s]%s\n" "$goto" "$clr"
    else
      printf "  \342\206\221/\342\206\223 move  space toggle  a/n all/none  p plan  D deploy  enter done  q quit%s\n" "$clr"
    fi
  else
    printf "  toggle: numbers (e.g. 1 3 5)  |  a=all  n=none  d=done  q=quit\n"
  fi
}

PENDING_ACTION=""   # set to plan|deploy when a hotkey breaks the selection loop

if [[ -n "$ACTION" ]]; then
  : # non-interactive: selection already resolved from flags; skip the menu entirely
elif ! $ASSUME_YES && $TUI; then
  cursor=0
  goto=""
  printf '\033[?25l'                       # hide the terminal cursor
  trap 'printf "\033[?25h"' EXIT           # …and always restore it on exit
  render "$cursor" "$goto"
  while true; do
    IFS= read -rsn1 key || key=""          # one raw, un-echoed keypress
    # Arrow keys arrive as an escape sequence: ESC [ A / ESC O A (and B/C/D).
    # bash >=4 gets a fractional timeout so a bare ESC doesn't block; bash 3.2
    # (macOS default) can't do sub-second timeouts, so there we read the two
    # trailing bytes without one — instant for a real arrow, only a bare ESC waits.
    if [[ $key == $'\033' ]]; then
      if [[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]; then
        read -rsn2 -t 0.1 seq || seq=""
      else
        read -rsn2 seq || seq=""
      fi
      key="$key$seq"
    fi
    case "$key" in
      $'\033[A'|$'\033OA'|k|K) cursor=$(( (cursor - 1 + ${#NAMES[@]}) % ${#NAMES[@]} )); goto="" ;;
      $'\033[B'|$'\033OB'|j|J) cursor=$(( (cursor + 1) % ${#NAMES[@]} )); goto="" ;;
      " ")   CHECK[$cursor]=$((1 - CHECK[$cursor])); goto="" ;;
      a|A)   for i in "${!CHECK[@]}"; do CHECK[$i]=1; done; goto="" ;;
      n|N)   for i in "${!CHECK[@]}"; do CHECK[$i]=0; done; goto="" ;;
      p)     PENDING_ACTION="plan"; goto=""; break ;;      # hotkey: plan the checked hosts
      D)     PENDING_ACTION="deploy"; goto=""; break ;;    # hotkey (shift-guarded): deploy them
      q|Q)   printf '\033[?25h'; echo; echo "  Aborted."; exit 0 ;;
      [0-9]) goto="$goto$key" ;;                       # build a host number
      $'\177'|$'\b') goto="${goto%?}" ;;               # backspace edits it
      "")    # Enter: commit a pending number (toggle it), else we're done.
        if [[ -n "$goto" ]]; then
          idx=$((10#$goto - 1))
          if [[ $idx -ge 0 && $idx -lt ${#NAMES[@]} ]]; then
            CHECK[$idx]=$((1 - CHECK[$idx])); cursor=$idx
          fi
          goto=""
        else
          break
        fi ;;
      *) : ;;                                          # ignore stray keys (bare ESC…)
    esac
    printf '\033[%dA' "$MENU_LINES"          # rewind, then repaint in place
    render "$cursor" "$goto"
  done
  printf '\033[?25h'                         # show cursor again
  trap - EXIT
elif ! $ASSUME_YES; then
  # Non-TTY (piped/CI): keep the original space-separated numeric protocol.
  while true; do
    render -1 ""
    printf "  > "
    read -r input || input="d"
    case "$input" in
      q|Q) echo "Aborted."; exit 0 ;;
      d|D|"") break ;;
      a|A) for i in "${!CHECK[@]}"; do CHECK[$i]=1; done ;;
      n|N) for i in "${!CHECK[@]}"; do CHECK[$i]=0; done ;;
      *)
        for tok in $input; do
          [[ "$tok" =~ ^[0-9]+$ ]] || continue
          idx=$((tok - 1))
          [[ $idx -ge 0 && $idx -lt ${#NAMES[@]} ]] || continue
          CHECK[$idx]=$((1 - CHECK[$idx]))
        done ;;
    esac
  done
fi

# ── 4. Generate the new hosts block from the checked items ───────────────────
gen_hosts() {
  for i in "${!NAMES[@]}"; do
    [[ ${CHECK[$i]} -eq 1 ]] || continue
    local line="    ${NAMES[$i]}: { ansible_host: ${IPS[$i]}"
    # Per-host user override only when it differs from the group default.
    if [[ -n "${USERS[$i]}" && "${USERS[$i]}" != "$DEFAULT_USER" ]]; then
      line+=", ansible_user: ${USERS[$i]}"
    fi
    line+=" }"
    echo "$line"
    # Warn (to stderr) if this host jumps somewhere other than the group jump.
    if [[ -n "${JUMPS[$i]}" && -n "$GROUP_JUMP" && "${JUMPS[$i]}" != "$GROUP_JUMP" ]]; then
      echo "  ! ${NAMES[$i]} uses ProxyJump ${JUMPS[$i]} (group default: $GROUP_JUMP) — add a per-host override if needed" >&2
    fi
  done
}

checked_count() { local n=0 i; for i in "${!CHECK[@]}"; do [[ ${CHECK[$i]} -eq 1 ]] && n=$((n + 1)); done; echo "$n"; }

# render_inventory DEST — full inventory (head through `hosts:` + checked block +
# `vars:` onward) written to DEST. Line numbers are recomputed each call so it stays
# correct across repeated writes (a prior write shifts the `vars:` line).
render_inventory() {
  local dest="$1" hln vln
  hln="$(grep -nE '^  hosts:' "$INVENTORY" | head -1 | cut -d: -f1)"
  vln="$(grep -nE '^  vars:'  "$INVENTORY" | head -1 | cut -d: -f1)"
  {
    head -n "$hln" "$INVENTORY"
    gen_hosts
    tail -n +"$vln" "$INVENTORY"
  } >"$dest"
}

# ── 5a. Write the selection into inventory.local.yml (backup first) ─────────────────
write_inventory() {
  local new; new="$(gen_hosts)"
  [[ -n "$new" ]] || { echo "  Nothing selected — inventory unchanged." >&2; return 1; }
  cp "$INVENTORY" "$INVENTORY.bak"
  render_inventory "$INVENTORY.tmp"
  mv "$INVENTORY.tmp" "$INVENTORY"
  echo "  ✓ Wrote $(printf '%s\n' "$new" | grep -c .) host(s) to $INVENTORY (backup: $INVENTORY.bak)"
  command -v ansible-inventory >/dev/null && {
    echo "  Validating..."
    ansible-inventory -i "$INVENTORY" --list >/dev/null && echo "  ✓ inventory parses"
  }
}

# choose_playbook — echo the selected playbook path (empty = cancel). Interactive.
choose_playbook() {
  local key
  printf "  Playbook:  1) update.yml   2) provision-ai.yml   (q cancel): " >&2
  read -r key || key="q"
  case "$key" in
    1) echo "$UPDATE_PLAYBOOK" ;;
    2) echo "$PROVISION_PLAYBOOK" ;;
    *) echo "" ;;
  esac
}

# resolve_playbook <update|provision|path|""> -> playbook path (default: update).
resolve_playbook() {
  case "${1:-}" in
    "" | update) echo "$UPDATE_PLAYBOOK" ;;
    provision)   echo "$PROVISION_PLAYBOOK" ;;
    *)           echo "$1" ;;
  esac
}

# run_playbook plan|deploy [playbook] — run the playbook against a throwaway
# inventory containing only the checked hosts (inventory.local.yml is left untouched).
# With no playbook arg it prompts (menu); deploy confirms unless --yes was given.
run_playbook() {
  local mode="$1" pb="${2:-}"
  command -v ansible-playbook >/dev/null || { echo "  ansible-playbook not found on PATH." >&2; return 1; }
  local n; n="$(checked_count)"
  [[ "$n" -gt 0 ]] || { echo "  Nothing selected — check at least one host first." >&2; return 1; }
  [[ -n "$pb" ]] || pb="$(choose_playbook)"
  [[ -n "$pb" ]] || { echo "  Cancelled."; return 0; }
  [[ -f "$pb" ]] || { echo "  Playbook not found: $pb" >&2; return 1; }
  if [[ "$mode" == deploy ]] && ! $ASSUME_YES; then
    printf "  Deploy to %s host(s) via %s? (y/N): " "$n" "$(basename "$pb")"
    local ok; read -r ok || ok="n"
    [[ "$ok" =~ ^[yY] ]] || { echo "  Cancelled."; return 0; }
  fi
  # A real `.yml` file is required so ansible picks its YAML inventory plugin
  # (a suffix-less temp file falls back to the ini parser and finds no hosts).
  local tmpd; tmpd="$(mktemp -d "${TMPDIR:-/tmp}/inv.XXXXXX")"
  local tmp="$tmpd/inventory.local.yml"
  render_inventory "$tmp"
  local flags=(); [[ "$mode" == plan ]] && flags=(--check --diff)
  echo "  + ansible-playbook -i <temp:${n} host(s)> $(basename "$pb") ${flags[*]}"
  local rc=0
  ansible-playbook -i "$tmp" "$pb" "${flags[@]}" || rc=$?
  rm -rf "$tmpd"
  return "$rc"
}

# ── 5b. Action menu — write / plan / deploy against the current selection ─────
action_menu() {
  local initial="${1:-}"
  [[ -n "$initial" ]] && { run_playbook "$initial" || true; }
  while true; do
    echo
    echo "  Selected hosts ($(checked_count)):"
    gen_hosts
    echo
    printf "  [w] write inventory   [p] plan   [D] deploy   [q] quit : "
    local a; read -r a || a="q"
    case "$a" in
      w|W)   write_inventory || true ;;
      p|P)   run_playbook plan || true ;;
      d|D)   run_playbook deploy || true ;;
      q|Q|"") break ;;
      *) : ;;
    esac
  done
}

# ── Non-interactive dispatch: an action flag runs directly, no menu ───────────
if [[ -n "$ACTION" ]]; then
  case "$ACTION" in
    write) write_inventory && exit 0 || exit 1 ;;
    plan | deploy)
      rc=0; run_playbook "$ACTION" "$(resolve_playbook "$PLAYBOOK_CHOICE")" || rc=$?
      exit "$rc" ;;
  esac
fi

NEW_HOSTS="$(gen_hosts)"
[[ -n "$NEW_HOSTS" ]] || { echo "Nothing selected — inventory unchanged." >&2; exit 0; }

echo
echo "  Resulting hosts: block:"
echo "  hosts:"
echo "$NEW_HOSTS"
echo

if $DRY_RUN; then echo "  (dry-run — inventory.local.yml not modified)"; exit 0; fi

# --yes stays fully non-interactive: write and exit (unchanged CI behavior).
if $ASSUME_YES; then write_inventory; exit $?; fi

# Interactive: drop into the action menu (pre-running a hotkey action if one fired).
action_menu "$PENDING_ACTION"
