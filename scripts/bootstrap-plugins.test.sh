#!/usr/bin/env bash
# Unit tests for the item-level plugin multiselect. No plugins are changed.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$ROOT/scripts/bootstrap-plugins.sh"
pass=0 fail=0

t_ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
t_ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pluginselect.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
RUN_LINE=$(awk '/^# ── Run/{print NR; exit}' "$SCRIPT")
sed -n "1,$((RUN_LINE - 1))p" "$SCRIPT" > "$TMP/defs.sh"
source "$TMP/defs.sh"

GROUP=(
  'one@market|One'
  'two@market|Two'
  'three@market|Three'
)

BASELINE_PLUGINS='one@market'
SELECTED_PLUGINS=''
select_group_plugins 'Test group' "${GROUP[@]}" <<< '2-3' >/dev/null
[ "$SELECTED_PLUGINS" = 'two@market,three@market' ] \
  && t_ok 'range selection chooses individual plugins' \
  || t_ko 'range selection chooses individual plugins' "got '$SELECTED_PLUGINS'"

BASELINE_PLUGINS='one@market,three@market'
SELECTED_PLUGINS=''
select_group_plugins 'Test group' "${GROUP[@]}" <<< '' >/dev/null
[ "$SELECTED_PLUGINS" = 'one@market,three@market' ] \
  && t_ok 'Enter keeps the installed items in that group' \
  || t_ko 'Enter keeps the installed items in that group' "got '$SELECTED_PLUGINS'"

# The sourced selector function consumes this variable.
# shellcheck disable=SC2034
BASELINE_PLUGINS='one@market,two@market'
SELECTED_PLUGINS=''
select_group_plugins 'Test group' "${GROUP[@]}" <<< 'none' >/dev/null
[ -z "$SELECTED_PLUGINS" ] \
  && t_ok 'none deselects every item in one group' \
  || t_ko 'none deselects every item in one group' "got '$SELECTED_PLUGINS'"

CALLS="$TMP/calls"
# The sourced function consumes RUN_OUT.
# shellcheck disable=SC2034
run_retry() { printf '%s\n' "$*" >> "$CALLS"; RUN_OUT=''; return 0; }
uninstall_plugin 'one@market' >/dev/null
grep -q '^claude plugin uninstall --keep-data one$' "$CALLS" \
  && t_ok 'deselection uninstalls the package while preserving plugin data' \
  || t_ko 'deselection uninstalls the package while preserving plugin data' "calls: [$(tr '\n' '|' < "$CALLS")]"

# Full-script reconciliation with a fake Claude CLI: saved state must avoid
# prompts, install selected entries, and uninstall installed-but-deselected ones.
FAKE_ROOT="$TMP/full"
mkdir -p "$FAKE_ROOT/bin" "$FAKE_ROOT/home" "$FAKE_ROOT/dotfiles/.local"
printf '%s\n' 'superpowers@superpowers-marketplace' > "$FAKE_ROOT/dotfiles/.local/.plugin-selection"
cat > "$FAKE_ROOT/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PLUGIN_TEST_CALLS"
if [ "$*" = 'plugin list' ]; then
  printf '  ❯ superpowers@superpowers-marketplace\n'
  printf '  ❯ autoresearch@autoresearch\n'
fi
exit 0
STUB
chmod +x "$FAKE_ROOT/bin/claude"

PLUGIN_TEST_CALLS="$FAKE_ROOT/calls" \
AI_DOTFILES_ROOT="$FAKE_ROOT/dotfiles" \
HOME="$FAKE_ROOT/home" \
PATH="$FAKE_ROOT/bin:$PATH" \
bash "$SCRIPT" </dev/null > "$FAKE_ROOT/output" 2>&1

if grep -q 'Select plugins' "$FAKE_ROOT/output"; then
  t_ko 'saved plugin state skips every multiselect prompt' "output contained a prompt"
else
  t_ok 'saved plugin state skips every multiselect prompt'
fi

grep -q '^plugin install superpowers@superpowers-marketplace$' "$FAKE_ROOT/calls" \
  && t_ok 'saved selected plugin is reconciled as installed' \
  || t_ko 'saved selected plugin is reconciled as installed'

grep -q '^plugin uninstall --keep-data autoresearch$' "$FAKE_ROOT/calls" \
  && t_ok 'installed but deselected plugin is uninstalled' \
  || t_ko 'installed but deselected plugin is uninstalled' "calls: [$(tr '\n' '|' < "$FAKE_ROOT/calls")]"

# Noninteractive updates must not reinstall a core plugin that the saved
# selection deliberately omitted.
: > "$FAKE_ROOT/calls"
printf '%s\n' 'feature-dev@claude-plugins-official' > "$FAKE_ROOT/dotfiles/.local/.plugin-selection"
PLUGIN_TEST_CALLS="$FAKE_ROOT/calls" \
  AI_DOTFILES_ROOT="$FAKE_ROOT/dotfiles" \
  HOME="$FAKE_ROOT/home" \
  PATH="$FAKE_ROOT/bin:$PATH" \
  bash "$SCRIPT" --core-only </dev/null > "$FAKE_ROOT/core-only-output" 2>&1

if grep -q '^plugin install superpowers@superpowers-marketplace$' "$FAKE_ROOT/calls"; then
  t_ko 'core-only update honors a deselected core plugin' 'superpowers was reinstalled'
else
  t_ok 'core-only update honors a deselected core plugin'
fi

grep -q '^plugin install feature-dev@claude-plugins-official$' "$FAKE_ROOT/calls" \
  && t_ok 'core-only update installs a saved core plugin' \
  || t_ko 'core-only update installs a saved core plugin' "calls: [$(tr '\n' '|' < "$FAKE_ROOT/calls")]"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
