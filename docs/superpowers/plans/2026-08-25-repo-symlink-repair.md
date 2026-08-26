# Repo Symlink Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect symlink drift between `~/.claude`/`~/.local/bin` and the ai-dotfiles checkout, then repair it from a single definition shared by every entry point.

**Architecture:** Phase 1 adds a read-only `links` probe to `scripts/preflight.sh`, which already runs from `just preflight` and at the end of `update.sh` — this is the only piece that reports drift without anyone knowing to run a repair. Phase 2 extracts every repo-owned linker from `setup.sh` into a new `lib/links.sh` and exposes one entry point, `relink_all`, called from `update.sh` and both `setup.sh` paths. Deletion of orphaned links is deliberately out of scope.

**Tech Stack:** bash, `tests/preflight/run.sh` harness, `jq` (existing preflight dependency), git.

## Global Constraints

- **bash 3.2 compatible.** `#!/bin/bash` is bash 3.2.57 on macOS. No `declare -A`, no `mapfile`/`readarray`, no `${x^^}`/`${x,,}`, no `&>>`.
- **`lib/links.sh` is sourced, never executed.** No side effects at source time — only function and default-variable definitions.
- **`scripts/preflight.sh` is `set -uo pipefail`, deliberately NOT `set -e`.** Probes are expected to fail; the script must continue.
- **`setup.sh` and `update.sh` are `set -euo pipefail`.** Any function called bare must return 0.
- **Never `readlink -f`.** GNU and BSD differ. Bare `readlink` prints a link's own target identically on both.
- **Never `find -xtype`.** GNU-only. Detect a dangling link with `[ -L "$p" ] && [ ! -e "$p" ]`.
- **Counter increments use `VAR=$(( VAR + 1 ))`.** Never `(( VAR++ ))` — it returns non-zero on a zero result and aborts under `set -e`.
- **Every path preflight reads is overridable** via a `PREFLIGHT_*` environment variable, so tests never touch the real `$HOME`.
- **Managed paths** (used verbatim in both phases): `~/.claude/scripts`, `~/.claude/hooks`, `~/.local/bin`, `~/.codex/prompts` (directories, depth 1), plus the single file `~/.claude/statusline.sh`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `lib/links.sh` | **Create.** Every repo-owned link: `link_file`, the five linkers, `relink_all`. Sourced by `setup.sh` and `update.sh`. |
| `scripts/preflight.sh` | **Modify.** Add `probe_links` + its `PREFLIGHT_*` overrides; call it from `main`. |
| `setup.sh` | **Modify.** Source `lib/links.sh`; delete the moved definitions; replace two open-coded blocks with `relink_all`. |
| `update.sh` | **Modify.** Source `lib/links.sh`; add step `1b`; export `LINKS_DRY_RUN` under `--dry-run`. |
| `tests/preflight/fixtures/links/` | **Create.** Fixture tree with a dangling and a stale-but-resolving link. |
| `tests/preflight/links_fixture.sh` | **Create.** Supplies `lib/links.sh`'s caller contract to the test harness. |
| `tests/preflight/run.sh` | **Modify.** Register both new test groups. |

Phase 1 (Tasks 1-2) ships and is useful alone. Phase 2 (Tasks 3-7) depends on it only for the fixture directory.

---

## Task 1: preflight links probe

**Files:**
- Modify: `scripts/preflight.sh:14-19` (path overrides), `scripts/preflight.sh:243` (insert `probe_links` before `check_preconditions`), `scripts/preflight.sh:487-501` (call it in `main`)
- Create: `tests/preflight/fixtures/links/` (fixture tree)
- Test: `tests/preflight/run.sh`

**Interfaces:**
- Consumes: `add_finding(class, name, verdict, detail, containable)` — existing, `scripts/preflight.sh:60`.
- Produces: `probe_links()`, emitting findings of class `link`. Verdicts: `fail` for dangling, `fail` for stale-but-resolving, `pass` otherwise. `containable` is always `no` — links are never auto-disabled by `--quarantine`.

- [ ] **Step 1: Build the fixture tree**

The fixture needs a fake checkout, a fake `HOME`, and three links: one healthy, one dangling, one stale-but-resolving.

```bash
mkdir -p tests/preflight/fixtures/links/checkout/scripts
mkdir -p tests/preflight/fixtures/links/old-ai-dotfiles/scripts
mkdir -p tests/preflight/fixtures/links/home/.claude/scripts

cd tests/preflight/fixtures/links
echo '#!/bin/bash' > checkout/scripts/healthy.sh
echo '#!/bin/bash' > old-ai-dotfiles/scripts/stale.sh
chmod +x checkout/scripts/healthy.sh old-ai-dotfiles/scripts/stale.sh

# healthy: points into the current checkout
ln -sfn ../../checkout/scripts/healthy.sh home/.claude/scripts/healthy.sh
# dangling: target does not exist
ln -sfn ../../checkout/scripts/gone.sh home/.claude/scripts/dangling.sh
# stale-but-resolving: resolves, but into a DIFFERENT ai-dotfiles checkout
ln -sfn ../../old-ai-dotfiles/scripts/stale.sh home/.claude/scripts/stale.sh
cd -
```

Relative link targets are used so the fixture is portable across machines.

- [ ] **Step 2: Write the failing tests**

Append to `tests/preflight/run.sh`, immediately before the final summary block:

```bash
# --- links probe -----------------------------------------------------------
# A dangling link is the incident condition. A stale-but-resolving link is the
# condition that would have made the incident INVISIBLE had the old checkout
# survived the move — a dangling-only check reports nothing for it.
links_fixture="$TESTS_DIR/fixtures/links"
out=$(PATH="$TESTS_DIR/stubs:$PATH" \
  PREFLIGHT_CLAUDE_JSON="$TESTS_DIR/fixtures/healthy/claude.json" \
  PREFLIGHT_SETTINGS_JSON="$TESTS_DIR/fixtures/healthy/settings.json" \
  PREFLIGHT_ENV_FILE="$TESTS_DIR/fixtures/healthy/env" \
  PREFLIGHT_SKILLS_DIR="$TESTS_DIR/fixtures/healthy/skills" \
  PREFLIGHT_LINK_DIRS="$links_fixture/home/.claude/scripts" \
  PREFLIGHT_LINK_FILES="" \
  PREFLIGHT_DOTFILES_DIR="$links_fixture/checkout" \
  bash "$REPO_DIR/scripts/preflight.sh" 2>&1); rc=$?

if grep -q "dangling.sh" <<<"$out"; then
  report pass "links probe reports a dangling link"
else
  report fail "links probe reports a dangling link" "$out"
fi

if grep -q "stale.sh" <<<"$out"; then
  report pass "links probe reports a stale-but-resolving link"
else
  report fail "links probe reports a stale-but-resolving link" "$out"
fi

if grep -qE "✔ .*healthy\.sh|✔ .*healthy" <<<"$out"; then
  report pass "links probe passes a correct link"
else
  report fail "links probe passes a correct link" "$out"
fi

if [ "$rc" -eq 1 ]; then
  report pass "links probe fails the run when drift is present"
else
  report fail "links probe fails the run when drift is present" "got rc=$rc"
fi

# The probe is read-only. Any write to the fixture is a defect.
links_tree_hash() {
  # names + link targets + sizes: catches a created, deleted, retargeted, or
  # rewritten file. `md5sum` on Linux, `md5` on macOS.
  find "$links_fixture" | sort | while IFS= read -r p; do
    printf '%s|%s|%s\n' "$p" "$(readlink "$p" 2>/dev/null)" "$(wc -c <"$p" 2>/dev/null)"
  done | { md5sum 2>/dev/null || md5; }
}
before=$(links_tree_hash)
PREFLIGHT_LINK_DIRS="$links_fixture/home/.claude/scripts" \
PREFLIGHT_DOTFILES_DIR="$links_fixture/checkout" \
  bash "$REPO_DIR/scripts/preflight.sh" >/dev/null 2>&1
after=$(links_tree_hash)
if [ "$before" = "$after" ]; then
  report pass "links probe writes nothing"
else
  report fail "links probe writes nothing" "fixture tree changed"
fi
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./tests/preflight/run.sh 2>&1 | grep -E "links probe"`
Expected: FAIL on all five — `probe_links` does not exist, so nothing mentions `dangling.sh`.

- [ ] **Step 4: Add the path overrides**

In `scripts/preflight.sh`, after line 19 (`MCP_TIMEOUT=...`):

```bash
# Managed link locations. Overridable so tests never read the real $HOME.
PREFLIGHT_LINK_DIRS="${PREFLIGHT_LINK_DIRS-$HOME/.claude/scripts:$HOME/.claude/hooks:$HOME/.local/bin:$HOME/.codex/prompts}"
PREFLIGHT_LINK_FILES="${PREFLIGHT_LINK_FILES-$HOME/.claude/statusline.sh}"
PREFLIGHT_DOTFILES_DIR="${PREFLIGHT_DOTFILES_DIR:-$DOTFILES_DIR}"
```

Note `${VAR-default}` (no colon) for the two lists: an intentionally empty value must stay empty, and `:-` would override it with the default.

- [ ] **Step 5: Implement probe_links**

Insert before `check_preconditions()` at `scripts/preflight.sh:279`:

```bash
# Repo-owned symlinks. Two failure modes, both silent today:
#   dangling            — target does not resolve (the aorus7 incident)
#   stale but resolving — resolves into a DIFFERENT ai-dotfiles checkout.
#     Had the old checkout survived the move, every link would have resolved
#     and a dangling-only check would have reported a clean machine.
probe_links() {
  local dir path target name
  local IFS_SAVE="$IFS"
  IFS=':'
  set -- $PREFLIGHT_LINK_DIRS
  IFS="$IFS_SAVE"
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    for path in "$dir"/*; do
      [ -L "$path" ] || continue
      _probe_one_link "$path"
    done
  done
  IFS=':'
  set -- $PREFLIGHT_LINK_FILES
  IFS="$IFS_SAVE"
  for path in "$@"; do
    [ -n "$path" ] || continue
    [ -L "$path" ] || continue
    _probe_one_link "$path"
  done
}

_probe_one_link() {
  local path="$1" target name
  name=$(basename "$path")
  target=$(readlink "$path")
  if [ ! -e "$path" ]; then
    add_finding link "$name" fail "dangling -> $target" no
    return
  fi
  case "$target" in
    "$PREFLIGHT_DOTFILES_DIR"|"$PREFLIGHT_DOTFILES_DIR"/*)
      add_finding link "$name" pass "current checkout" no ;;
    */ai-dotfiles/*)
      add_finding link "$name" fail "stale but resolving -> $target" no ;;
    *)
      add_finding link "$name" pass "not repo-owned" no ;;
  esac
}
```

`set --` plus `IFS` splitting is the bash 3.2-safe way to iterate a
colon-separated list without arrays or `readarray`.

- [ ] **Step 6: Call it from main and label the class**

In `main()` at `scripts/preflight.sh:501`, after `probe_skills`:

```bash
  probe_links
```

In `render_human()`, alongside the other `render_class` calls, add:

```bash
  render_class link "REPO LINKS"
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `./tests/preflight/run.sh`
Expected: all five `links probe` cases PASS, and every pre-existing case still passes. The healthy fixture must still exit 0 — it defines no link dirs, so `probe_links` emits nothing.

- [ ] **Step 8: Commit**

```bash
git add scripts/preflight.sh tests/preflight/run.sh tests/preflight/fixtures/links
git commit -m "preflight: report dangling and stale-but-resolving repo links"
```

---

## Task 2: run the probe across the fleet

**Files:**
- No code changes. This task is the acceptance gate for Phase 1.

**Interfaces:**
- Consumes: `probe_links` from Task 1.
- Produces: a recorded per-node result; no artifact other than the commit note.

- [ ] **Step 1: Run locally**

Run: `just preflight`
Expected: a `REPO LINKS` section listing this machine's links. This machine was repaired earlier in the session, so expect 0 failures.

- [ ] **Step 2: Run on each reachable node**

```bash
for h in macstudio aorus aorus4 aorus5 aorus6 aorus7 aorus8; do
  printf "=== %-10s " "$h"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$h" \
    'cd ~/Developer/ai-dotfiles 2>/dev/null || cd ~/ai-dotfiles; bash scripts/preflight.sh 2>&1 | sed -n "/REPO LINKS/,/^$/p"' \
    2>&1 | tail -5
done
```

Expected: aorus2 and aorus3 unreachable (powered off at last survey). Every other node reports its link state. **Record which nodes report stale-but-resolving links** — that count is the evidence base for whether pruning is ever worth building.

- [ ] **Step 3: Commit the finding**

If any node reports drift, note it in the spec's Follow-up section and commit:

```bash
git add docs/superpowers/specs/2026-08-25-repo-symlink-repair-design.md
git commit -m "docs: record the fleet-wide links baseline"
```

---

## Task 3: lib/links.sh with link_file

**Files:**
- Create: `lib/links.sh`
- Create: `tests/preflight/links_fixture.sh`
- Modify: `tests/preflight/run.sh` (register the new group)

**Interfaces:**
- Consumes: caller-defined `DOTFILES_DIR`, `CLAUDE_DIR`, and `ok`/`warn`/`skip` helpers.
- Produces:
  - `link_file(src, dst)` → always returns 0. Increments exactly one of `LINK_CHANGED`, `LINK_OK`, `LINK_SKIPPED`, `LINK_FAILED`.
  - Globals `LINK_CHANGED`, `LINK_OK`, `LINK_SKIPPED`, `LINK_FAILED` (integers).
  - `LINKS_DRY_RUN` — any non-empty value means dry run.

- [ ] **Step 1: Write the test fixture**

Create `tests/preflight/links_fixture.sh`:

```bash
#!/bin/bash
# Supplies lib/links.sh's caller contract to the test harness: a throwaway
# checkout and HOME, plus capturing ok/warn/skip stubs. Sourced, not executed.

links_fixture_setup() {
  LINKS_TMP=$(mktemp -d)
  export HOME="$LINKS_TMP/home"
  DOTFILES_DIR="$LINKS_TMP/checkout"
  CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$DOTFILES_DIR/scripts" "$DOTFILES_DIR/hooks" "$DOTFILES_DIR/bin" \
           "$DOTFILES_DIR/codex/prompts" "$CLAUDE_DIR" "$HOME/.local/bin"
  echo '#!/bin/bash' > "$DOTFILES_DIR/statusline.sh"
  LINKS_OUT=""
  unset LINKS_DRY_RUN
  echo "$LINKS_TMP"
}

ok()   { LINKS_OUT="$LINKS_OUT[ok] $1"$'\n'; }
warn() { LINKS_OUT="$LINKS_OUT[warn] $1"$'\n'; }
skip() { LINKS_OUT="$LINKS_OUT[skip] $1"$'\n'; }
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/preflight/run.sh`, before the summary block:

```bash
# --- lib/links.sh ----------------------------------------------------------
source "$REPO_DIR/tests/preflight/links_fixture.sh"

links_case() {  # links_case <name> <body-fn>
  local name="$1" body="$2" tmp
  tmp=$(links_fixture_setup); add_cleanup_dir "$tmp"
  source "$REPO_DIR/lib/links.sh"
  LINK_CHANGED=0; LINK_OK=0; LINK_SKIPPED=0; LINK_FAILED=0
  "$body"
}

# 1. a dangling link is repointed at the current checkout
_t_repoint() {
  echo 'x' > "$DOTFILES_DIR/scripts/a.sh"
  mkdir -p "$CLAUDE_DIR/scripts"
  ln -sfn "/nonexistent/a.sh" "$CLAUDE_DIR/scripts/a.sh"
  link_file "$DOTFILES_DIR/scripts/a.sh" "$CLAUDE_DIR/scripts/a.sh"
  if [ "$(readlink "$CLAUDE_DIR/scripts/a.sh")" = "$DOTFILES_DIR/scripts/a.sh" ] \
     && [ "$LINK_CHANGED" -eq 1 ]; then
    report pass "link_file repoints a dangling link"
  else
    report fail "link_file repoints a dangling link" "changed=$LINK_CHANGED"
  fi
}
links_case repoint _t_repoint

# 2. a correct link is untouched and silent
_t_verified() {
  echo 'x' > "$DOTFILES_DIR/scripts/b.sh"
  mkdir -p "$CLAUDE_DIR/scripts"
  ln -sfn "$DOTFILES_DIR/scripts/b.sh" "$CLAUDE_DIR/scripts/b.sh"
  LINKS_OUT=""
  link_file "$DOTFILES_DIR/scripts/b.sh" "$CLAUDE_DIR/scripts/b.sh"
  if [ "$LINK_OK" -eq 1 ] && [ -z "$LINKS_OUT" ]; then
    report pass "link_file leaves a correct link untouched and silent"
  else
    report fail "link_file leaves a correct link untouched and silent" "ok=$LINK_OK out=$LINKS_OUT"
  fi
}
links_case verified _t_verified

# 3. dst is a directory -> refused, directory survives
_t_dstdir() {
  echo 'x' > "$DOTFILES_DIR/scripts/c.sh"
  mkdir -p "$CLAUDE_DIR/scripts/c.sh"
  link_file "$DOTFILES_DIR/scripts/c.sh" "$CLAUDE_DIR/scripts/c.sh"
  if [ -d "$CLAUDE_DIR/scripts/c.sh" ] && [ "$LINK_FAILED" -eq 1 ]; then
    report pass "link_file refuses a directory destination"
  else
    report fail "link_file refuses a directory destination" "failed=$LINK_FAILED"
  fi
}
links_case dstdir _t_dstdir

# 4. dst is a regular file -> backed up, then replaced
_t_dstfile() {
  echo 'new' > "$DOTFILES_DIR/scripts/d.sh"
  mkdir -p "$CLAUDE_DIR/scripts"
  echo 'original' > "$CLAUDE_DIR/scripts/d.sh"
  link_file "$DOTFILES_DIR/scripts/d.sh" "$CLAUDE_DIR/scripts/d.sh"
  if [ -L "$CLAUDE_DIR/scripts/d.sh" ] \
     && grep -rq original "$CLAUDE_DIR/.backups" 2>/dev/null; then
    report pass "link_file backs up a regular file before replacing it"
  else
    report fail "link_file backs up a regular file before replacing it" "$(ls -R "$CLAUDE_DIR" 2>&1)"
  fi
}
links_case dstfile _t_dstfile

# 5. src missing -> skip, no link created
_t_srcmissing() {
  mkdir -p "$CLAUDE_DIR/scripts"
  link_file "$DOTFILES_DIR/scripts/nope.sh" "$CLAUDE_DIR/scripts/nope.sh"
  if [ ! -e "$CLAUDE_DIR/scripts/nope.sh" ] && [ ! -L "$CLAUDE_DIR/scripts/nope.sh" ] \
     && [ "$LINK_SKIPPED" -eq 1 ]; then
    report pass "link_file skips a missing source"
  else
    report fail "link_file skips a missing source" "skipped=$LINK_SKIPPED"
  fi
}
links_case srcmissing _t_srcmissing

# 6. an exported counter does not leak into the run
_t_exported() {
  echo 'x' > "$DOTFILES_DIR/scripts/e.sh"
  export LINK_CHANGED=7
  LINK_CHANGED=0; LINK_OK=0; LINK_SKIPPED=0; LINK_FAILED=0
  link_file "$DOTFILES_DIR/scripts/e.sh" "$CLAUDE_DIR/scripts/e.sh"
  local got="$LINK_CHANGED"
  unset LINK_CHANGED
  if [ "$got" -eq 1 ]; then
    report pass "an exported counter does not survive explicit assignment"
  else
    report fail "an exported counter does not survive explicit assignment" "got $got, want 1"
  fi
}
links_case exported _t_exported
```

- [ ] **Step 3: Run to verify they fail**

Run: `./tests/preflight/run.sh 2>&1 | grep link_file`
Expected: FAIL — `lib/links.sh` does not exist, so `source` errors.

- [ ] **Step 4: Write lib/links.sh**

```bash
#!/bin/bash
# Repo-owned symlinks, shared by setup.sh and update.sh.
# Sourced, never executed. No side effects at source time.
#
# Caller contract: DOTFILES_DIR, CLAUDE_DIR, and the ok/warn/skip helpers must
# be defined before relink_all runs. Must stay bash 3.2 compatible — #!/bin/bash
# is 3.2.57 on macOS.

# Any non-empty value means dry run. Defaulted here so sourcing from setup.sh,
# which has no --dry-run, cannot trip `set -u`.
LINKS_DRY_RUN="${LINKS_DRY_RUN:-}"

# Always returns 0: a non-zero return would abort the caller at every bare
# call site under `set -e`. Callers learn what happened from the counters.
link_file() {
  local src="$1" dst="$2" dst_dir backup_dir

  if [ ! -e "$src" ]; then
    skip "$(basename "$dst") — source missing"
    LINK_SKIPPED=$(( LINK_SKIPPED + 1 ))
    return 0
  fi

  # Already correct: touch nothing, print nothing. Ends the churn where every
  # run removed and recreated every link.
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    LINK_OK=$(( LINK_OK + 1 ))
    return 0
  fi

  # A directory here would make `ln -s` create the link INSIDE it, at a path
  # nothing reads.
  if [ -d "$dst" ] && [ ! -L "$dst" ]; then
    warn "$(basename "$dst") is a directory — refusing to link over it"
    LINK_FAILED=$(( LINK_FAILED + 1 ))
    return 0
  fi

  if [ -n "$LINKS_DRY_RUN" ]; then
    ok "$(basename "$dst") -> ${src#"$DOTFILES_DIR"/} (dry run)"
    LINK_CHANGED=$(( LINK_CHANGED + 1 ))
    return 0
  fi

  dst_dir=$(dirname "$dst")
  if ! mkdir -p "$dst_dir" 2>/dev/null; then
    warn "$(basename "$dst") — cannot create $dst_dir"
    LINK_FAILED=$(( LINK_FAILED + 1 ))
    return 0
  fi

  if [ -f "$dst" ] && [ ! -L "$dst" ]; then
    backup_dir="$CLAUDE_DIR/.backups/setup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp "$dst" "$backup_dir/$(basename "$dst")"
    warn "Backed up existing $(basename "$dst") to $backup_dir/"
  fi

  # -f -n: atomic replace, and never descend into a symlinked directory.
  if ln -sfn "$src" "$dst" 2>/dev/null; then
    ok "$(basename "$dst") -> ${src#"$DOTFILES_DIR"/}"
    LINK_CHANGED=$(( LINK_CHANGED + 1 ))
  else
    warn "$(basename "$dst") — could not create link"
    LINK_FAILED=$(( LINK_FAILED + 1 ))
  fi
  return 0
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `./tests/preflight/run.sh 2>&1 | grep link_file`
Expected: all six PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/links.sh tests/preflight/links_fixture.sh tests/preflight/run.sh
git commit -m "links: add lib/links.sh with link_file change detection"
```

---

## Task 4: the five linkers

**Files:**
- Modify: `lib/links.sh` (append)
- Modify: `tests/preflight/run.sh` (append tests)

**Interfaces:**
- Consumes: `link_file` from Task 3.
- Produces: `link_bin_tools()`, `link_claude_hooks()`, `link_codex_prompts()`, `link_agent_instructions()`, `link_statusline()`, `link_repo_scripts()` — each returns 0.

- [ ] **Step 1: Write the failing tests**

Append to `tests/preflight/run.sh`:

```bash
# 7. link_statusline does not chmod through a link it did not create
_t_statusline_dryrun() {
  LINKS_DRY_RUN=1
  link_statusline
  unset LINKS_DRY_RUN
  if [ ! -e "$CLAUDE_DIR/statusline.sh" ]; then
    report pass "link_statusline makes no link and no chmod under dry run"
  else
    report fail "link_statusline makes no link and no chmod under dry run" "link exists"
  fi
}
links_case statusline_dryrun _t_statusline_dryrun

# 8. a missing source directory is skipped, not failed
_t_nobindir() {
  rmdir "$DOTFILES_DIR/bin"
  link_bin_tools
  if [ "$LINK_FAILED" -eq 0 ]; then
    report pass "link_bin_tools skips a missing bin/ without failing"
  else
    report fail "link_bin_tools skips a missing bin/ without failing" "failed=$LINK_FAILED"
  fi
}
links_case nobindir _t_nobindir

# 9. hooks with a dotted stem are repo-side helpers, never linked as hooks
_t_dottedhook() {
  echo 'x' > "$DOTFILES_DIR/hooks/real.sh"
  echo 'x' > "$DOTFILES_DIR/hooks/helper.test.sh"
  link_claude_hooks
  if [ -L "$CLAUDE_DIR/hooks/real.sh" ] && [ ! -e "$CLAUDE_DIR/hooks/helper.test.sh" ]; then
    report pass "link_claude_hooks skips dotted-stem helpers"
  else
    report fail "link_claude_hooks skips dotted-stem helpers" "$(ls "$CLAUDE_DIR/hooks" 2>&1)"
  fi
}
links_case dottedhook _t_dottedhook
```

- [ ] **Step 2: Run to verify they fail**

Run: `./tests/preflight/run.sh 2>&1 | grep -E "link_statusline|link_bin_tools|link_claude_hooks"`
Expected: FAIL with "command not found".

- [ ] **Step 3: Append the linkers to lib/links.sh**

Move these three verbatim from `setup.sh:795-833`, then add the rest:

```bash
# Repo CLI helpers (bin/* -> ~/.local/bin/<name>). Symlinked so a repo pull
# updates the live tools.
link_bin_tools() {
  [ -d "$DOTFILES_DIR/bin" ] || { skip "no bin/ in this checkout"; return 0; }
  local f
  for f in "$DOTFILES_DIR"/bin/*; do
    [ -f "$f" ] || continue
    chmod +x "$f"
    link_file "$f" "$HOME/.local/bin/$(basename "$f")"
  done
  return 0
}

# Claude Code hooks. The shared profile settings.json references these by
# $HOME path, so a machine that skips this step gets a "No such file or
# directory" error on every hook fire.
link_claude_hooks() {
  [ -d "$DOTFILES_DIR/hooks" ] || { skip "no hooks/ in this checkout"; return 0; }
  local f
  for f in "$DOTFILES_DIR"/hooks/*.sh "$DOTFILES_DIR"/hooks/*.py; do
    [ -f "$f" ] || continue
    # A real hook is <name>.<ext>. A dotted stem (foo.test.sh) is a repo-side
    # helper and must not be installed as a hook.
    case "$(basename "$f")" in *.*.*) continue ;; esac
    link_file "$f" "$CLAUDE_DIR/hooks/$(basename "$f")"
  done
  return 0
}

# Codex custom prompts, typed as /<name> in the Codex TUI.
link_codex_prompts() {
  [ -d "$DOTFILES_DIR/codex/prompts" ] || { skip "no codex/prompts/ in this checkout"; return 0; }
  local f
  for f in "$DOTFILES_DIR"/codex/prompts/*.md; do
    [ -f "$f" ] || continue
    link_file "$f" "$HOME/.codex/prompts/$(basename "$f")"
  done
  return 0
}

link_repo_scripts() {
  [ -d "$DOTFILES_DIR/scripts" ] || { skip "no scripts/ in this checkout"; return 0; }
  local f name
  for f in "$DOTFILES_DIR"/scripts/*.sh; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    link_file "$f" "$CLAUDE_DIR/scripts/$name"
    [ -L "$CLAUDE_DIR/scripts/$name" ] && chmod +x "$CLAUDE_DIR/scripts/$name"
  done
  return 0
}

# The chmod follows the symlink onto the checkout's own file, which is what
# git tracks. Guarded on the link actually existing: under dry run there is
# no link, and chmod through a dangling link fails and would abort `set -e`.
link_statusline() {
  link_file "$DOTFILES_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
  if [ -z "$LINKS_DRY_RUN" ] && [ -L "$CLAUDE_DIR/statusline.sh" ] \
     && [ -e "$CLAUDE_DIR/statusline.sh" ]; then
    chmod +x "$CLAUDE_DIR/statusline.sh"
  fi
  return 0
}

# AGENTS.md/GEMINI.md all point at the assembled CLAUDE.md. The guard is
# correct for these four links and gates ONLY them — the hook, bin, and
# codex linkers moved out to relink_all, so hook installation no longer
# depends on a file unrelated to hooks.
link_agent_instructions() {
  local canonical="$CLAUDE_DIR/CLAUDE.md"
  [ -f "$canonical" ] || { warn "CLAUDE.md not found; skipping agent-instruction symlinks"; return 0; }
  link_file "$canonical" "$HOME/.codex/AGENTS.md"
  link_file "$canonical" "$HOME/.config/opencode/AGENTS.md"
  link_file "$canonical" "$HOME/.gemini/GEMINI.md"
  link_file "$canonical" "$HOME/AGENTS.md"
  return 0
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `./tests/preflight/run.sh 2>&1 | grep -E "link_statusline|link_bin_tools|link_claude_hooks"`
Expected: all three PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/links.sh tests/preflight/run.sh
git commit -m "links: move the five linkers into lib/links.sh"
```

---

## Task 5: relink_all

**Files:**
- Modify: `lib/links.sh` (append)
- Modify: `tests/preflight/run.sh` (append tests)

**Interfaces:**
- Consumes: every linker from Task 4.
- Produces: `relink_all()` → always returns 0. Resets the four counters, runs every linker including `link_agent_instructions`, prints one summary line.

- [ ] **Step 1: Write the failing tests**

```bash
# 10. relink_all zeroes counters on entry — an exported value must not leak
_t_relink_reset() {
  export LINK_CHANGED=99
  echo 'x' > "$DOTFILES_DIR/scripts/f.sh"
  LINKS_OUT=""
  relink_all
  unset LINK_CHANGED
  if ! grep -q "99" <<<"$LINKS_OUT"; then
    report pass "relink_all zeroes counters, ignoring an exported value"
  else
    report fail "relink_all zeroes counters, ignoring an exported value" "$LINKS_OUT"
  fi
}
links_case relink_reset _t_relink_reset

# 11. AGENTS.md failures are counted, not erased by the reset. This was the
# review's broadest finding: called BEFORE relink_all, they printed under
# "0 failed".
_t_agents_counted() {
  echo 'x' > "$CLAUDE_DIR/CLAUDE.md"
  relink_all
  if [ -L "$HOME/AGENTS.md" ]; then
    report pass "relink_all links AGENTS.md and counts it"
  else
    report fail "relink_all links AGENTS.md and counts it" "$LINKS_OUT"
  fi
}
links_case agents_counted _t_agents_counted

# 12. the four counters account for every link attempted
_t_counter_sum() {
  echo 'x' > "$DOTFILES_DIR/scripts/g.sh"
  echo 'x' > "$DOTFILES_DIR/hooks/h.sh"
  relink_all
  total=$(( LINK_CHANGED + LINK_OK + LINK_SKIPPED + LINK_FAILED ))
  if [ "$total" -gt 0 ]; then
    report pass "relink_all counters sum to the links attempted"
  else
    report fail "relink_all counters sum to the links attempted" "total=$total"
  fi
}
links_case counter_sum _t_counter_sum

# 13. a repair is a warn, not an ok — 24 silent repairs under a checkmark
# would hide exactly the condition that caused the incident
_t_repair_warns() {
  echo 'x' > "$DOTFILES_DIR/scripts/i.sh"
  mkdir -p "$CLAUDE_DIR/scripts"
  ln -sfn /nonexistent/i.sh "$CLAUDE_DIR/scripts/i.sh"
  LINKS_OUT=""
  relink_all
  if grep -q "\[warn\].*changed" <<<"$LINKS_OUT"; then
    report pass "relink_all summarises a repair as a warn"
  else
    report fail "relink_all summarises a repair as a warn" "$LINKS_OUT"
  fi
}
links_case repair_warns _t_repair_warns
```

- [ ] **Step 2: Run to verify they fail**

Run: `./tests/preflight/run.sh 2>&1 | grep relink_all`
Expected: FAIL with "relink_all: command not found".

- [ ] **Step 3: Implement relink_all**

```bash
# The single entry point. Every call site calls this and nothing else.
#
# link_agent_instructions runs INSIDE this function rather than before it: if
# it ran first, its link_file failures would increment LINK_FAILED and then be
# erased by the reset below, so a failed AGENTS.md link would print under
# "0 failed". Inside, every link is counted once and update.sh gains the
# ability to repair those four links, which it otherwise could not reach.
relink_all() {
  : "${DOTFILES_DIR:?relink_all requires DOTFILES_DIR}"
  : "${CLAUDE_DIR:?relink_all requires CLAUDE_DIR}"

  # Assigned, not defaulted: ${VAR:-0} does not stop an exported value
  # leaking in — `LINK_CHANGED=7 bash -c 'echo ${LINK_CHANGED:-0}'` prints 7.
  LINK_CHANGED=0
  LINK_OK=0
  LINK_SKIPPED=0
  LINK_FAILED=0

  link_statusline
  link_repo_scripts
  link_claude_hooks
  link_bin_tools
  link_codex_prompts
  link_agent_instructions

  local summary
  summary="$LINK_CHANGED changed, $LINK_OK verified, $LINK_SKIPPED skipped, $LINK_FAILED failed"
  [ -n "$LINKS_DRY_RUN" ] && summary="$summary  (dry run)"
  if [ "$LINK_CHANGED" -gt 0 ] || [ "$LINK_FAILED" -gt 0 ]; then
    warn "$summary"
  else
    ok "$summary"
  fi
  return 0
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `./tests/preflight/run.sh 2>&1 | grep relink_all`
Expected: all four PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/links.sh tests/preflight/run.sh
git commit -m "links: add relink_all as the single entry point"
```

---

## Task 6: wire setup.sh

**Files:**
- Modify: `setup.sh:32-33` (source), `setup.sh:588-608` (delete `link_file`), `setup.sh:780-833` (delete the moved linkers), `setup.sh:991-1000` (replace), `setup.sh:1444-1453` (replace)
- Test: `tests/preflight/run.sh`

**Interfaces:**
- Consumes: `relink_all` from Task 5.
- Produces: no new symbols. `setup.sh` keeps `install_settings`, which calls `link_file` from the lib.

- [ ] **Step 1: Write the failing test**

```bash
# 14. every entry script sources the lib and calls relink_all
for f in setup.sh update.sh; do
  if grep -q 'source .*lib/links\.sh' "$REPO_DIR/$f" && grep -q 'relink_all' "$REPO_DIR/$f"; then
    report pass "$f sources lib/links.sh and calls relink_all"
  else
    report fail "$f sources lib/links.sh and calls relink_all" "missing one or both"
  fi
done

# 15. the moved definitions exist in exactly one place
if [ "$(grep -c '^link_file() {' "$REPO_DIR/setup.sh")" -eq 0 ]; then
  report pass "link_file is defined only in lib/links.sh"
else
  report fail "link_file is defined only in lib/links.sh" "still in setup.sh"
fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `./tests/preflight/run.sh 2>&1 | grep -E "sources lib/links|defined only"`
Expected: FAIL — `setup.sh` still defines `link_file` and sources nothing.

- [ ] **Step 3: Add the source line**

At `setup.sh:33`, after the `lib/integrations.sh` source:

```bash
# shellcheck source=lib/links.sh
source "$DOTFILES_DIR/lib/links.sh"
```

- [ ] **Step 4: Delete the moved definitions**

Delete from `setup.sh`: `link_file` (588-608), `link_bin_tools` (795-803), `link_claude_hooks` (811-824), `link_codex_prompts` (826-833), and `link_agent_instructions` (780-790). Leave `install_settings`, `link_codex_prompts`'s neighbours, and everything else untouched.

- [ ] **Step 5: Replace the install-path block**

`setup.sh:991-1000` — replace:

```bash
  # Link statusline
  link_file "$DOTFILES_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
  chmod +x "$CLAUDE_DIR/statusline.sh"

  # Link scripts
  for script in "$DOTFILES_DIR"/scripts/*.sh; do
    [ -f "$script" ] || continue
    link_file "$script" "$CLAUDE_DIR/scripts/$(basename "$script")"
    chmod +x "$CLAUDE_DIR/scripts/$(basename "$script")"
  done
```

with:

```bash
  # Every repo-owned link, from one definition
  relink_all
```

Also delete the now-redundant `link_agent_instructions` call at `setup.sh:986` — `relink_all` runs it.

- [ ] **Step 6: Replace the cmd_update block**

`setup.sh:1444-1453` — replace the identical statusline + scripts pair with `relink_all`, and delete the `link_agent_instructions` call at `setup.sh:1441`.

- [ ] **Step 7: Verify**

Run: `bash -n setup.sh && ./tests/preflight/run.sh`
Expected: syntax OK; cases 14 and 15 PASS; every earlier case still passes.

Run: `just preflight`
Expected: `REPO LINKS` reports 0 failures on this machine.

- [ ] **Step 8: Commit**

```bash
git add setup.sh tests/preflight/run.sh
git commit -m "setup: call relink_all instead of open-coding link installation"
```

---

## Task 7: wire update.sh

**Files:**
- Modify: `update.sh:34` (source), `update.sh:52-58` (dry-run export), `update.sh:158` (insert step 1b)
- Test: `tests/preflight/run.sh` (case 14 from Task 6 already covers update.sh)

**Interfaces:**
- Consumes: `relink_all` from Task 5.
- Produces: nothing new.

- [ ] **Step 1: Add the source line**

At `update.sh:34`, after `DOTFILES_DIR` is set (line 45) — place it immediately after the `DOTFILES_DIR=` assignment, since the source depends on it:

```bash
# shellcheck source=lib/links.sh
source "$DOTFILES_DIR/lib/links.sh"
```

- [ ] **Step 2: Export the dry-run flag**

In the argument loop at `update.sh:54`, change:

```bash
    --dry-run)     DRY_RUN="yes" ;;
```

to:

```bash
    --dry-run)     DRY_RUN="yes"; export LINKS_DRY_RUN=1 ;;
```

- [ ] **Step 3: Insert step 1b**

After the backup's closing `ok "Backup: ..."` line at `update.sh:158`, before `# ── 2. Upgrade ──`:

```bash
# ── 1b. Repo links ───────────────────────────────────────────────
# After the backup so a repair is recoverable; before the upgrade so the
# links are correct for the rest of the run and the next session — which is
# when hooks actually fire. update.sh performs no git pull, so no linkable
# content arrives after this point (step 4 vendors into skills/, which is
# copied, not linked).
header "Repo links"
relink_all
```

- [ ] **Step 4: Verify**

Run: `bash -n update.sh`
Expected: syntax OK.

Run: `./update.sh --dry-run`
Expected: a `Repo links` section reporting `(dry run)`, no link modified, and the run completes without aborting. This is the path that would have crashed under `set -e` had `link_statusline` chmod'd through a dangling link.

Run: `git status --short`
Expected: clean — a dry run writes nothing.

Run: `./tests/preflight/run.sh`
Expected: every case passes.

- [ ] **Step 5: Commit**

```bash
git add update.sh
git commit -m "update: repair repo links as step 1b"
```

---

## Task 8: fleet rollout

**Files:**
- No code changes. Acceptance gate for Phase 2.

**Interfaces:**
- Consumes: Tasks 1-7, pushed to `origin/main`.

- [ ] **Step 1: Publish**

```bash
./deploy.sh
```

Servers pull from `origin/main`, so config changes must be published before the fleet run.

- [ ] **Step 2: Run the fleet update**

```bash
cd ansible-ai && ansible-playbook update.yml --limit aorus_ai
```

Expected: each node runs `setup.sh update`, which now calls `relink_all`. Offline hosts (aorus2, aorus3 at last survey) are skipped — the playbook reports them as unreachable.

- [ ] **Step 3: Confirm the baseline is clean**

```bash
for h in macstudio aorus aorus4 aorus5 aorus6 aorus7 aorus8; do
  printf "=== %-10s " "$h"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$h" \
    'cd ~/Developer/ai-dotfiles 2>/dev/null || cd ~/ai-dotfiles; bash scripts/preflight.sh 2>&1 | sed -n "/REPO LINKS/,/^$/p" | tail -3' \
    2>&1 | tail -3
done
```

Expected: every reachable node reports 0 link failures. **Acceptance for this plan is every node reporting a clean links check** — including aorus2 and aorus3 once they are powered on.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
| --- | --- |
| Phase 1 — detection (dangling + stale-but-resolving) | 1, 2 |
| `lib/links.sh` caller contract, bash 3.2 ceiling | 3 (Global Constraints, `relink_all` asserts) |
| `link_file` change detection, edge cases, `ln -sfn` | 3 |
| `link_statusline` chmod guard + dry run | 4 (test 7) |
| Five linkers moved | 4 |
| `relink_all` folds in `link_agent_instructions` | 5 (test 11) |
| Counters assigned not defaulted | 5 (test 10) |
| Repair summarised as `warn` | 5 (test 13) |
| Three call sites | 6, 7 |
| `--dry-run` exports `LINKS_DRY_RUN` | 7 |
| Deferred: pruning, concurrency | Not implemented — by design |
| Follow-up: aorus2/aorus3 | 8, step 3 |

**Type consistency:** `relink_all`, `link_file`, `link_statusline`, `link_repo_scripts`, `link_bin_tools`, `link_claude_hooks`, `link_codex_prompts`, `link_agent_instructions`, and the four `LINK_*` counters are spelled identically in every task. `LINKS_DRY_RUN` is exported in Task 7 and read in Tasks 3-5.

**Known gap:** Task 6 step 4 gives line ranges from the current `setup.sh`. Deleting earlier ranges shifts later ones — delete from the bottom up, or locate each function by name.
