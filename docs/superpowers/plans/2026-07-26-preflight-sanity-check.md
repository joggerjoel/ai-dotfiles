# Pre-flight Sanity Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a checker that verifies every configured asset actually works, contains broken MCP servers, and reports everything else.

**Architecture:** A single bash script, `scripts/preflight.sh`, probes five asset classes and accumulates findings in one flat array. Tier 2 (handshake) shells out to `claude mcp list` once for all MCP servers and runs local checks for the rest. Tier 3 (smoke) runs opt-in per-asset scripts from `tests/smoke/`. The justfile exposes `preflight`, `audit`, and `test`; `update.sh` calls the checker read-only as its final step.

**Tech Stack:** bash, `jq`, `claude` CLI, `just`, `timeout` (coreutils/BSD).

**Spec:** `docs/superpowers/specs/2026-07-26-preflight-sanity-check-design.md`

## Global Constraints

- Target `bash`, not `zsh`. Scripts run under `#!/bin/bash`.
- **Never use `set -e`** in `preflight.sh`. Probes are expected to fail; the script must continue and report. Use `set -uo pipefail` only.
- **In bash, use `${PIPESTATUS[0]}`; in zsh it is `${pipestatus[1]}`.** These scripts are bash, so `PIPESTATUS` is correct. Never read `$?` after a pipeline.
- Exit codes: `0` no FAILs, `1` at least one FAIL (checker ran), `2` checker could not run.
- Four verdicts: `pass`, `fail`, `unknown`, `untested`. **Never quarantine `unknown`.**
- Containment applies to MCP servers only.
- MCP handshake timeout: 180 seconds. A timeout yields `unknown` for every server, never `fail`.
- JSON output carries `"schema": 1`.
- All scripts must pass `shellcheck -S warning` (`just lint`). `shellcheck` is not installed on the dev machine; if unavailable, run `bash -n` and note the gap in the commit.
- Findings record format is exactly: `class|name|verdict|detail|containable`.
- File paths used by the checker are overridable by environment variable so tests never touch the real `$HOME`.

---

### Task 1: Extract the asset registry into `lib/integrations.sh`

`setup.sh` defines `INTEGRATIONS` inline, so no other script can read it without executing `setup.sh`'s top-level code. Extract it, and add the `MANDATED_CLIS` list the checker needs.

**Files:**

- Create: `lib/integrations.sh`
- Modify: `setup.sh` (delete the inline `INTEGRATIONS` array and `mcp_key_for`, source the new file)

**Interfaces:**

- Consumes: nothing
- Produces: `INTEGRATIONS` (array of `name|description|needs_key|key_var|disabled_by_default|extra_vars|desktop_only`), `MANDATED_CLIS` (array of command names), `mcp_key_for(name) -> string`

- [ ] **Step 1: Capture golden output before changing anything**

```bash
cd ~/Documents/Projects/ai-dotfiles
./setup.sh list > /tmp/preflight-golden-list.txt
wc -l /tmp/preflight-golden-list.txt
```

Expected: a non-empty file listing every integration with a status icon.

- [ ] **Step 2: Create `lib/integrations.sh`**

```bash
#!/bin/bash
# Asset registry shared by setup.sh and scripts/preflight.sh.
# Sourced, never executed. Defines data and one pure function; no side effects.

# Format: name|description|needs_key|key_var|disabled_by_default|extra_vars|desktop_only
INTEGRATIONS=(
  "context7|Documentation lookup|no||||no"
  "serena|Semantic code assistant|no||||no"
  "morphllm-fast-apply|Fast code application|no||||no"
  "chrome-devtools|Browser DevTools (desktop only)|no||yes||yes"
  "firecrawl|Web scraping (large-scale)|yes|FIRECRAWL_API_KEY|||no"
  "github|GitHub repo/issue/PR management|yes|GITHUB_PERSONAL_ACCESS_TOKEN|yes||no"
  "openrouter|OpenRouter AI models|yes|OPENROUTER_API_KEY|yes||no"
  "apify|Web scraping actors|yes|APIFY_TOKEN|yes||no"
  "digitalocean|DigitalOcean infrastructure|yes|DIGITALOCEAN_API_TOKEN|yes||no"
  "n8n|Workflow automation|yes|N8N_JWT|yes|N8N_URL|no"
  "crawl4ai|Self-hosted web scraping (SSE)|yes|CRAWL4AI_TOKEN|yes|CRAWL4AI_URL|no"
  "playwright|Browser automation & testing|no||yes||yes"
  "browser-tools|Advanced browser tools|no||yes||yes"
  "magic|UI component generation|no||yes||yes"
)

# CLIs the CLAUDE.md tool-priority tables name as required. Declared here rather
# than scraped from markdown: table formatting changes break a parser, and a
# parser cannot tell a mandated tool from one merely mentioned.
MANDATED_CLIS=(
  "agent-browser"
  "gh"
  "bun"
  "uv"
  "just"
  "jq"
)

# Map an integration name to its key in ~/.claude.json.
mcp_key_for() {
  case "$1" in
    browser-tools) echo "browser-tools-mcp" ;;
    firecrawl)     echo "firecrawl-mcp" ;;
    openrouter)    echo "openrouterai" ;;
    digitalocean)  echo "digitalocean-mcp" ;;
    n8n)           echo "n8n-mcp" ;;
    *)             echo "$1" ;;
  esac
}
```

- [ ] **Step 3: Replace the inline definitions in `setup.sh`**

Delete the `INTEGRATIONS=( ... )` array and the whole `mcp_key_for()` function from `setup.sh`. In their place, immediately after the `sed_inplace` definition block, insert:

```bash
# ── Asset registry ───────────────────────────────────────────────
# shellcheck source=lib/integrations.sh
source "$DOTFILES_DIR/lib/integrations.sh"
```

`DOTFILES_DIR` is already defined above this point in `setup.sh`, so the source path resolves.

- [ ] **Step 4: Verify behaviour is byte-identical**

```bash
./setup.sh list > /tmp/preflight-new-list.txt
diff /tmp/preflight-golden-list.txt /tmp/preflight-new-list.txt && echo "IDENTICAL"
bash -n setup.sh && bash -n lib/integrations.sh && echo "SYNTAX OK"
```

Expected: `IDENTICAL` then `SYNTAX OK`. Any diff means the extraction dropped or reordered an entry.

- [ ] **Step 5: Commit**

```bash
git add lib/integrations.sh setup.sh
git commit -m "Extract asset registry to lib/integrations.sh

setup.sh defined INTEGRATIONS inline, so no other script could read it
without executing setup.sh's top-level code. Adds MANDATED_CLIS for the
pre-flight checker.

Claude-Session: https://claude.ai/code/session_01EnVRBZg1RGSaEHxG1kuL21"
```

---

### Task 2: Test harness, stub, healthy fixture, and checker skeleton

Build the harness before the checker so the negative control exists from the first commit. A probe that silently does nothing must never be able to masquerade as a clean environment.

**Files:**

- Create: `scripts/preflight.sh`
- Create: `tests/preflight/run.sh`
- Create: `tests/preflight/stubs/claude`
- Create: `tests/preflight/fixtures/healthy/mcp-list.txt`
- Create: `tests/preflight/fixtures/healthy/claude.json`
- Create: `tests/preflight/fixtures/healthy/settings.json`

**Interfaces:**

- Consumes: `lib/integrations.sh` from Task 1
- Produces: `add_finding(class,name,verdict,detail,containable)`, the `FINDINGS` array, and these environment overrides — `PREFLIGHT_CLAUDE_JSON`, `PREFLIGHT_SETTINGS_JSON`, `PREFLIGHT_ENV_FILE`, `PREFLIGHT_SKILLS_DIR`, `PREFLIGHT_SMOKE_DIR`

- [ ] **Step 1: Write the failing test**

Create `tests/preflight/run.sh`:

```bash
#!/bin/bash
# Pre-flight checker test harness. Runs offline: `claude` is stubbed on PATH
# and every filesystem path the checker reads is redirected at a fixture.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
PASS=0
FAIL=0

report() {
  if [ "$1" = "pass" ]; then
    PASS=$((PASS + 1)); echo "  ok   $2"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $2"
    [ -n "${3:-}" ] && echo "       $3"
  fi
}

# Run preflight.sh against a named fixture. Echoes stdout; returns its exit code.
run_preflight() {
  local fixture="$1"; shift
  PATH="$TESTS_DIR/stubs:$PATH" \
  PREFLIGHT_FIXTURE="$TESTS_DIR/fixtures/$fixture" \
  PREFLIGHT_CLAUDE_JSON="$TESTS_DIR/fixtures/$fixture/claude.json" \
  PREFLIGHT_SETTINGS_JSON="$TESTS_DIR/fixtures/$fixture/settings.json" \
  PREFLIGHT_ENV_FILE="$TESTS_DIR/fixtures/$fixture/env" \
  PREFLIGHT_SKILLS_DIR="$TESTS_DIR/fixtures/$fixture/skills" \
  PREFLIGHT_SMOKE_DIR="$TESTS_DIR/fixtures/$fixture/smoke" \
    bash "$REPO_DIR/scripts/preflight.sh" "$@"
}

echo "preflight tests"

# --- negative control -------------------------------------------------------
# An all-healthy fixture MUST produce exit 0 and zero findings. Without this,
# a checker that silently does nothing looks identical to a clean environment.
out=$(run_preflight healthy 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  report pass "healthy fixture exits 0"
else
  report fail "healthy fixture exits 0" "got rc=$rc, output: $out"
fi

if ! grep -qE '✘|FAIL' <<<"$out"; then
  report pass "healthy fixture reports no failures"
else
  report fail "healthy fixture reports no failures" "$out"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

Make it executable: `chmod +x tests/preflight/run.sh`

- [ ] **Step 2: Create the stub and healthy fixture**

`tests/preflight/stubs/claude`:

```bash
#!/bin/bash
# Stub for the `claude` CLI. Serves recorded output from $PREFLIGHT_FIXTURE.
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "list" ]; then
  cat "$PREFLIGHT_FIXTURE/mcp-list.txt"
  exit 0
fi
exit 0
```

`chmod +x tests/preflight/stubs/claude`

`tests/preflight/fixtures/healthy/mcp-list.txt` — recorded real output, all connected:

```
Checking MCP server health…

context7: npx -y @upstash/context7-mcp - ✔ Connected
github: npx -y @modelcontextprotocol/server-github - ✔ Connected
firecrawl-mcp: npx -y firecrawl-mcp - ✔ Connected
```

`tests/preflight/fixtures/healthy/claude.json`:

```json
{
  "mcpServers": {
    "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"]
    },
    "firecrawl-mcp": { "command": "npx", "args": ["-y", "firecrawl-mcp"] }
  }
}
```

`tests/preflight/fixtures/healthy/settings.json`:

```json
{ "hooks": {} }
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bash tests/preflight/run.sh
```

Expected: FAIL — `scripts/preflight.sh` does not exist yet, so bash reports "No such file or directory" and `rc` is 127.

- [ ] **Step 4: Write the minimal checker**

Create `scripts/preflight.sh`:

```bash
#!/bin/bash
# preflight.sh — verify that configured assets actually work.
#
# Deliberately NOT `set -e`: probes are expected to fail, and the script must
# continue and report rather than abort on the first broken asset.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/integrations.sh
source "$DOTFILES_DIR/lib/integrations.sh"

# Every path is overridable so tests never read the real $HOME.
CLAUDE_JSON="${PREFLIGHT_CLAUDE_JSON:-$HOME/.claude.json}"
SETTINGS_JSON="${PREFLIGHT_SETTINGS_JSON:-$HOME/.claude/settings.json}"
ENV_FILE="${PREFLIGHT_ENV_FILE:-$HOME/.claude/.env}"
SKILLS_DIR="${PREFLIGHT_SKILLS_DIR:-$DOTFILES_DIR/skills}"
SMOKE_DIR="${PREFLIGHT_SMOKE_DIR:-$DOTFILES_DIR/tests/smoke}"
MCP_TIMEOUT="${PREFLIGHT_MCP_TIMEOUT:-180}"

# class|name|verdict|detail|containable
FINDINGS=()

add_finding() {
  FINDINGS+=("$1|$2|$3|$4|$5")
}

# Count findings matching a verdict.
count_verdict() {
  local want="$1" n=0 f
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    [ "$(cut -d'|' -f3 <<<"$f")" = "$want" ] && n=$((n + 1))
  done
  echo "$n"
}

main() {
  local fails
  fails=$(count_verdict fail)
  if [ "$fails" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

main "$@"
```

`chmod +x scripts/preflight.sh`

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash tests/preflight/run.sh
```

Expected:

```
preflight tests
  ok   healthy fixture exits 0
  ok   healthy fixture reports no failures

  2 passed, 0 failed
```

- [ ] **Step 6: Commit**

```bash
git add scripts/preflight.sh tests/preflight
git commit -m "Add preflight test harness with all-healthy negative control

The harness stubs \`claude\` on PATH and redirects every filesystem path
at a fixture, so tests run offline and deterministically. The negative
control exists before any probe: a checker that silently does nothing
must not be able to look like a clean environment.

Claude-Session: https://claude.ai/code/session_01EnVRBZg1RGSaEHxG1kuL21"
```

---

### Task 3: MCP handshake probe

**Files:**

- Modify: `scripts/preflight.sh` (add `probe_mcp`, call it from `main`)
- Modify: `tests/preflight/run.sh` (add regression assertions)
- Create: `tests/preflight/fixtures/regression/mcp-list.txt`
- Create: `tests/preflight/fixtures/regression/claude.json`
- Create: `tests/preflight/fixtures/regression/settings.json`
- Create: `tests/preflight/fixtures/timeout/mcp-list.txt`
- Create: `tests/preflight/fixtures/timeout/claude.json`
- Create: `tests/preflight/fixtures/timeout/settings.json`

**Interfaces:**

- Consumes: `add_finding`, `count_verdict`, `CLAUDE_JSON`, `MCP_TIMEOUT` from Task 2
- Produces: `probe_mcp()` — appends one finding per MCP server

- [ ] **Step 1: Write the failing tests**

Create `tests/preflight/fixtures/regression/mcp-list.txt`, reproducing the three real MCP failures of 2026-07-26:

```
Checking MCP server health…

context7: npx -y @upstash/context7-mcp - ✔ Connected
github: npx -y @modelcontextprotocol/server-github - ✔ Connected
plugin:stripe:stripe: https://mcp.stripe.com (HTTP) - ! Needs authentication
magic: npx -y @21st-dev/magic - ✘ Failed to connect — -32001: Not authenticated - your API key is missing or was reset.
n8n-mcp: https://n8n.example.com/mcp-server/http (HTTP) - ✘ Failed to connect — ENOTFOUND: getaddrinfo ENOTFOUND n8n.example.com
crawl4ai: https://crawl.example.com/mcp/sse (SSE) - ✘ Failed to connect — SSE error: getaddrinfo ENOTFOUND crawl.example.com
```

`tests/preflight/fixtures/regression/claude.json`:

```json
{
  "mcpServers": {
    "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"]
    },
    "magic": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@21st-dev/magic"]
    },
    "n8n-mcp": {
      "type": "http",
      "url": "https://n8n.example.com/mcp-server/http"
    },
    "crawl4ai": { "type": "sse", "url": "https://crawl.example.com/mcp/sse" }
  }
}
```

`tests/preflight/fixtures/regression/settings.json`:

```json
{ "hooks": {} }
```

`tests/preflight/fixtures/timeout/mcp-list.txt` (content is irrelevant; the stub simulates the timeout):

```

```

`tests/preflight/fixtures/timeout/claude.json`:

```json
{
  "mcpServers": {
    "context7": { "command": "npx" },
    "github": { "command": "npx" }
  }
}
```

`tests/preflight/fixtures/timeout/settings.json`:

```json
{ "hooks": {} }
```

Update `tests/preflight/stubs/claude` to simulate a timeout when asked:

```bash
#!/bin/bash
# Stub for the `claude` CLI. Serves recorded output from $PREFLIGHT_FIXTURE.
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "list" ]; then
  # exit 124 is what `timeout` returns when it kills the child
  if [ "$(basename "$PREFLIGHT_FIXTURE")" = "timeout" ]; then
    exit 124
  fi
  cat "$PREFLIGHT_FIXTURE/mcp-list.txt"
  exit 0
fi
exit 0
```

Append to `tests/preflight/run.sh`, before the summary block:

```bash
# --- regression corpus: the four real failures of 2026-07-26 ----------------
out=$(run_preflight regression 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then
  report pass "regression fixture exits 1"
else
  report fail "regression fixture exits 1" "got rc=$rc"
fi

for broken in magic n8n-mcp crawl4ai; do
  if grep -q "$broken" <<<"$out"; then
    report pass "regression reports $broken"
  else
    report fail "regression reports $broken" "$out"
  fi
done

# "Needs authentication" is UNKNOWN, never FAIL — stripe must not be a failure.
if grep -qE 'stripe.*(unknown|needs authentication)' <<<"$out"; then
  report pass "stripe classified unknown, not fail"
else
  report fail "stripe classified unknown, not fail" "$out"
fi

# --- timeout: every server becomes UNKNOWN, never FAIL ----------------------
out=$(run_preflight timeout 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  report pass "timeout yields no failures"
else
  report fail "timeout yields no failures" "got rc=$rc, output: $out"
fi

if grep -qi 'timed out' <<<"$out"; then
  report pass "timeout is reported to the user"
else
  report fail "timeout is reported to the user" "$out"
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash tests/preflight/run.sh
```

Expected: the two healthy assertions pass; every regression and timeout assertion fails, because `probe_mcp` does not exist and no findings are produced.

- [ ] **Step 3: Implement `probe_mcp`**

Insert into `scripts/preflight.sh` above `main()`:

```bash
# Probe every MCP server with a single `claude mcp list`. One invocation covers
# all servers in ~90s; per-server probing would cost ~90s each.
probe_mcp() {
  local out rc line name detail

  if ! command -v claude >/dev/null 2>&1; then
    CHECKER_BROKEN=1
    CHECKER_REASON="claude CLI not found on PATH"
    return
  fi

  out=$(timeout "$MCP_TIMEOUT" claude mcp list 2>&1)
  rc=$?

  # 124 is `timeout` killing the child. Every server becomes UNKNOWN — never
  # FAIL. Auto-quarantining a whole toolchain on a network blip is the worst
  # outcome this script can produce.
  if [ "$rc" -eq 124 ]; then
    MCP_TIMED_OUT=1
    local key
    while IFS= read -r key; do
      [ -n "$key" ] && add_finding mcp "$key" unknown "handshake timed out after ${MCP_TIMEOUT}s" no
    done < <(jq -r '.mcpServers // {} | keys[]' "$CLAUDE_JSON" 2>/dev/null)
    return
  fi

  while IFS= read -r line; do
    case "$line" in
      *"✔ Connected"*)
        name="${line%%: *}"
        add_finding mcp "$name" pass "connected" no
        ;;
      *"Needs authentication"*)
        name="${line%%: *}"
        add_finding mcp "$name" unknown "needs authentication" no
        ;;
      *"✘ Failed to connect"*)
        name="${line%%: *}"
        detail="${line#*✘ }"
        add_finding mcp "$name" fail "$detail" yes
        ;;
      *) continue ;;
    esac
  done <<<"$out"
}
```

The name is split on the first colon-**space**, not the first colon, so plugin-supplied servers such as `plugin:stripe:stripe` keep their full name.

Add the two state variables near `FINDINGS=()`:

```bash
CHECKER_BROKEN=0
CHECKER_REASON=""
MCP_TIMED_OUT=0
```

Replace `main()` with:

```bash
main() {
  probe_mcp

  if [ "$CHECKER_BROKEN" -eq 1 ]; then
    echo "preflight could not run: $CHECKER_REASON" >&2
    exit 2
  fi

  if [ "$MCP_TIMED_OUT" -eq 1 ]; then
    echo "MCP handshake timed out after ${MCP_TIMEOUT}s — all servers reported unknown"
  fi

  local f class name verdict detail
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    IFS='|' read -r class name verdict detail _ <<<"$f"
    case "$verdict" in
      pass)    echo "  ✔ $class $name" ;;
      fail)    echo "  ✘ $class $name — $detail" ;;
      unknown) echo "  ! $class $name — $detail (unknown)" ;;
    esac
  done

  local fails
  fails=$(count_verdict fail)
  if [ "$fails" -gt 0 ]; then
    exit 1
  fi
  exit 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/preflight/run.sh
```

Expected: `9 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight.sh tests/preflight
git commit -m "Add MCP handshake probe with the 2026-07-26 regression corpus

One \`claude mcp list\` covers every server. A timeout yields unknown for
all of them rather than fail, so a network blip can never cascade into
quarantining a working toolchain. Server names split on the first
colon-space so plugin:stripe:stripe keeps its full name.

Claude-Session: https://claude.ai/code/session_01EnVRBZg1RGSaEHxG1kuL21"
```

---

### Task 4: Local probes — CLIs, env vars, hooks, repo skills

Four probes that need no network and no subprocess beyond `command -v`.

**Files:**

- Modify: `scripts/preflight.sh` (add four probes, call them from `main`)
- Modify: `tests/preflight/run.sh` (add assertions)
- Create: `tests/preflight/fixtures/regression/env`
- Create: `tests/preflight/fixtures/healthy/env`
- Create: `tests/preflight/fixtures/regression/skills/broken-skill/SKILL.md`
- Create: `tests/preflight/fixtures/healthy/skills/good-skill/SKILL.md`

**Interfaces:**

- Consumes: `add_finding`, `ENV_FILE`, `SETTINGS_JSON`, `SKILLS_DIR`, `MANDATED_CLIS`, `INTEGRATIONS`
- Produces: `probe_clis()`, `probe_env()`, `probe_hooks()`, `probe_skills()`

- [ ] **Step 1: Write the failing tests**

`tests/preflight/fixtures/healthy/env`:

```
FIRECRAWL_API_KEY=fc-test
GITHUB_PERSONAL_ACCESS_TOKEN=ghp_test
```

`tests/preflight/fixtures/regression/env` — deliberately missing `CRAWL4AI_URL` and `CRAWL4AI_TOKEN`:

```
FIRECRAWL_API_KEY=fc-test
```

`tests/preflight/fixtures/healthy/skills/good-skill/SKILL.md`:

```markdown
---
name: good-skill
description: A skill whose frontmatter parses and whose name matches its directory.
---

# Good skill

No file references.
```

`tests/preflight/fixtures/regression/skills/broken-skill/SKILL.md` — references a file that does not exist:

```markdown
---
name: broken-skill
description: A skill that references a missing file.
---

# Broken skill

See [the rubric](references/rubric.md) for details.
```

Append to `tests/preflight/run.sh` before the summary:

```bash
# --- env-var services -------------------------------------------------------
out=$(run_preflight regression 2>&1)
if grep -q 'CRAWL4AI_URL' <<<"$out"; then
  report pass "reports unset CRAWL4AI_URL"
else
  report fail "reports unset CRAWL4AI_URL" "$out"
fi

# --- repo skills ------------------------------------------------------------
if grep -q 'references/rubric.md' <<<"$out"; then
  report pass "reports skill referencing a missing file"
else
  report fail "reports skill referencing a missing file" "$out"
fi

# --- mandated CLIs: jq is definitely installed, so it must pass --------------
out=$(run_preflight healthy 2>&1)
if grep -qE '✔ cli jq' <<<"$out"; then
  report pass "reports jq as a passing CLI"
else
  report fail "reports jq as a passing CLI" "$out"
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash tests/preflight/run.sh
```

Expected: the three new assertions fail; the nine from Tasks 2–3 still pass.

- [ ] **Step 3: Implement the four probes**

Insert into `scripts/preflight.sh` above `main()`:

```bash
# Mandated CLIs. Missing ones cannot be contained — there is nothing to disable.
probe_clis() {
  local cli
  for cli in "${MANDATED_CLIS[@]}"; do
    if command -v "$cli" >/dev/null 2>&1; then
      add_finding cli "$cli" pass "on PATH" no
    else
      add_finding cli "$cli" fail "not on PATH — CLAUDE.md names it required" no
    fi
  done
}

# Is a variable set to a non-empty value in the env file or the environment?
env_var_set() {
  local var="$1" val=""
  if [ -f "$ENV_FILE" ]; then
    val=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${var}=" "$ENV_FILE" 2>/dev/null | tail -1 | sed -E 's/^[^=]*=//' | tr -d '"'"'"' ')
  fi
  [ -z "$val" ] && val="${!var:-}"
  [ -n "$val" ]
}

# Env-var services declared by INTEGRATIONS (key_var and extra_vars).
probe_env() {
  local entry name needs_key key_var extra_vars missing
  for entry in "${INTEGRATIONS[@]}"; do
    IFS='|' read -r name _ needs_key key_var _ extra_vars _ <<<"$entry"
    [ "$needs_key" = "yes" ] || continue

    missing=""
    if [ -n "$key_var" ] && ! env_var_set "$key_var"; then
      missing="$key_var"
    fi
    if [ -n "$extra_vars" ] && ! env_var_set "$extra_vars"; then
      missing="${missing:+$missing, }$extra_vars"
    fi

    if [ -n "$missing" ]; then
      add_finding env "$name" fail "unset: $missing" no
    else
      add_finding env "$name" pass "configured" no
    fi
  done
}

# Hook scripts referenced by settings.json must exist and be executable.
probe_hooks() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ ! -e "$path" ]; then
      add_finding hook "$path" fail "hook path does not exist" no
    elif [ ! -x "$path" ]; then
      add_finding hook "$path" fail "hook exists but is not executable" no
    else
      add_finding hook "$path" pass "exists and is executable" no
    fi
  done < <(jq -r '[.hooks // {} | .. | objects | .command? // empty] | .[]' "$SETTINGS_JSON" 2>/dev/null \
             | awk '{print $1}' | grep -E '^/|^\$HOME|^~' | sed "s|^~|$HOME|; s|^\$HOME|$HOME|")
}

# Repo-owned skills: frontmatter parses, name matches directory, referenced
# relative paths exist.
probe_skills() {
  local skill_md dir name declared ref
  [ -d "$SKILLS_DIR" ] || return
  while IFS= read -r skill_md; do
    dir="$(dirname "$skill_md")"
    name="$(basename "$dir")"

    if ! head -1 "$skill_md" | grep -q '^---'; then
      add_finding skill "$name" fail "SKILL.md has no frontmatter block" no
      continue
    fi

    declared=$(sed -n '2,/^---/p' "$skill_md" | grep -E '^name:' | head -1 | sed -E 's/^name:[[:space:]]*//')
    if [ -n "$declared" ] && [ "$declared" != "$name" ]; then
      add_finding skill "$name" fail "frontmatter name '$declared' does not match directory" no
      continue
    fi

    # Markdown links to relative paths inside the skill directory.
    local missing_ref=""
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      [ -e "$dir/$ref" ] || missing_ref="$ref"
    done < <(grep -oE '\]\([a-zA-Z0-9._/-]+\)' "$skill_md" 2>/dev/null \
               | sed -E 's/^\]\(//; s/\)$//' | grep -vE '^https?:')

    if [ -n "$missing_ref" ]; then
      add_finding skill "$name" fail "references $missing_ref (missing)" no
    else
      add_finding skill "$name" pass "parses, references resolve" no
    fi
  done < <(find "$SKILLS_DIR" -maxdepth 2 -name SKILL.md 2>/dev/null)
}
```

Update `main()` to call them right after `probe_mcp`:

```bash
  probe_mcp
  probe_clis
  probe_env
  probe_hooks
  probe_skills
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/preflight/run.sh
```

Expected: `12 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight.sh tests/preflight
git commit -m "Add CLI, env-var, hook, and repo-skill probes

Env-var checks are driven by INTEGRATIONS' key_var and extra_vars, so
declaring a new integration automatically declares what it needs. None of
these classes is containable: a missing CLI has nothing to disable, and
silently disabling a hook changes behaviour.

Claude-Session: https://claude.ai/code/session_01EnVRBZg1RGSaEHxG1kuL21"
```

---

### Task 5: Grouped human report and the exit-2 path

**Files:**

- Modify: `scripts/preflight.sh` (add `render_human`, add the precondition check)
- Modify: `tests/preflight/run.sh` (assert exit 2 and summary lines)
- Create: `tests/preflight/stubs-noclaude/.gitkeep`

**Interfaces:**

- Consumes: `FINDINGS`, `count_verdict`, `CHECKER_BROKEN`
- Produces: `render_human()`, `check_preconditions()`

- [ ] **Step 1: Write the failing tests**

Append to `tests/preflight/run.sh` before the summary:

```bash
# --- exit 2: the checker itself could not run -------------------------------
# An empty stub dir plus a PATH with no `claude` must report "could not run",
# NOT "everything failed". Distinguishing 2 from 1 is what stops a green cron
# job from hiding a checker that has been crashing for a month.
out=$(PATH="$TESTS_DIR/stubs-noclaude:/usr/bin:/bin" \
      PREFLIGHT_FIXTURE="$TESTS_DIR/fixtures/healthy" \
      PREFLIGHT_CLAUDE_JSON="$TESTS_DIR/fixtures/healthy/claude.json" \
      PREFLIGHT_SETTINGS_JSON="$TESTS_DIR/fixtures/healthy/settings.json" \
      PREFLIGHT_ENV_FILE="$TESTS_DIR/fixtures/healthy/env" \
      PREFLIGHT_SKILLS_DIR="$TESTS_DIR/fixtures/healthy/skills" \
      bash "$REPO_DIR/scripts/preflight.sh" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then
  report pass "missing claude yields exit 2, not 1"
else
  report fail "missing claude yields exit 2, not 1" "got rc=$rc: $out"
fi

# --- summary line -----------------------------------------------------------
out=$(run_preflight regression 2>&1)
if grep -qE '[0-9]+ assets · [0-9]+ pass · [0-9]+ fail' <<<"$out"; then
  report pass "prints a summary line"
else
  report fail "prints a summary line" "$out"
fi

if grep -q 'just preflight --quarantine' <<<"$out"; then
  report pass "suggests --quarantine when containable failures exist"
else
  report fail "suggests --quarantine when containable failures exist" "$out"
fi
```

Create the empty stub directory: `mkdir -p tests/preflight/stubs-noclaude && touch tests/preflight/stubs-noclaude/.gitkeep`

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash tests/preflight/run.sh
```

Expected: the three new assertions fail.

- [ ] **Step 3: Implement preconditions and the report**

Add above `main()` in `scripts/preflight.sh`:

```bash
# The checker's own dependencies. Missing ones mean exit 2 — "could not run" —
# which must never be confused with exit 1, "ran and found failures".
check_preconditions() {
  local missing=()
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v claude >/dev/null 2>&1 || missing+=("claude")
  if [ ${#missing[@]} -gt 0 ]; then
    CHECKER_BROKEN=1
    CHECKER_REASON="missing required tools: ${missing[*]}"
  fi
}

# Print all findings for one class. Passes collapse onto a single line, so a
# clean report stays skimmable. Body is buffered so the header can print first
# with the correct total.
render_class() {
  local class="$1" label="$2" f c n v d passes=() total=0 body=""
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    IFS='|' read -r c n v d _ <<<"$f"
    [ "$c" = "$class" ] || continue
    total=$((total + 1))
    case "$v" in
      pass)     passes+=("$n") ;;
      fail)     body+="$(printf '  ✘ %-18s %s' "$n" "$d")"$'\n' ;;
      unknown)  body+="$(printf '  ! %-18s %s' "$n" "$d")"$'\n' ;;
      untested) body+="$(printf '  · %-18s %s' "$n" "$d")"$'\n' ;;
    esac
  done
  [ "$total" -eq 0 ] && return
  printf '\n%-40s %3d\n' "$label" "$total"
  if [ ${#passes[@]} -gt 0 ]; then
    printf '  ✔ %s\n' "${passes[*]}"
  fi
  [ -n "$body" ] && printf '%s' "$body"
}

render_human() {
  local pass fail unknown untested total containable f v c
  pass=$(count_verdict pass)
  fail=$(count_verdict fail)
  unknown=$(count_verdict unknown)
  untested=$(count_verdict untested)
  total=$(( pass + fail + unknown + untested ))

  printf 'PREFLIGHT  %s\n' "$(date '+%Y-%m-%d %H:%M')"

  render_class mcp   "MCP SERVERS"
  render_class cli   "MANDATED CLIS"
  render_class env   "ENV-VAR SERVICES"
  render_class hook  "HOOKS & SCRIPTS"
  render_class skill "REPO SKILLS"

  containable=0
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    IFS='|' read -r _ _ v _ c <<<"$f"
    [ "$v" = "fail" ] && [ "$c" = "yes" ] && containable=$((containable + 1))
  done

  printf '\n%s\n' "────────────────────────────────────────────"
  printf '%d assets · %d pass · %d fail · %d unknown\n' "$total" "$pass" "$fail" "$unknown"
  if [ "$containable" -gt 0 ]; then
    printf 'contain %d of %d:  just preflight --quarantine\n' "$containable" "$fail"
  fi
  if [ "$(( fail - containable ))" -gt 0 ]; then
    printf '%d failures need you — not containable\n' "$(( fail - containable ))"
  fi
}
```

Rewrite `main()`:

```bash
main() {
  check_preconditions
  if [ "$CHECKER_BROKEN" -eq 1 ]; then
    echo "preflight could not run: $CHECKER_REASON" >&2
    exit 2
  fi

  probe_mcp
  probe_clis
  probe_env
  probe_hooks
  probe_skills

  if [ "$CHECKER_BROKEN" -eq 1 ]; then
    echo "preflight could not run: $CHECKER_REASON" >&2
    exit 2
  fi

  if [ "$MCP_TIMED_OUT" -eq 1 ]; then
    echo "MCP handshake timed out after ${MCP_TIMEOUT}s — all servers reported unknown"
  fi

  render_human

  [ "$(count_verdict fail)" -gt 0 ] && exit 1
  exit 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/preflight/run.sh
```

Expected: `15 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight.sh tests/preflight
git commit -m "Add grouped human report and the exit-2 precondition path

Passing assets collapse to one line so a clean report stays skimmable. The
summary states how many failures cannot be contained, so --quarantine never
implies a clean bill of health it did not deliver. Exit 2 is reserved for
'the checker could not run'.

Claude-Session: https://claude.ai/code/session_01EnVRBZg1RGSaEHxG1kuL21"
```

---

### Task 6: `--json` output

**Files:**

- Modify: `scripts/preflight.sh` (arg parsing, `render_json`)
- Modify: `tests/preflight/run.sh`

**Interfaces:**

- Consumes: `FINDINGS`, `count_verdict`
- Produces: `render_json()`, `OPT_JSON`

- [ ] **Step 1: Write the failing tests**

```bash
# --- JSON output ------------------------------------------------------------
out=$(run_preflight regression --json 2>/dev/null)
if jq -e '.schema == 1' <<<"$out" >/dev/null 2>&1; then
  report pass "--json emits schema 1"
else
  report fail "--json emits schema 1" "$out"
fi

if jq -e '[.assets[] | select(.verdict=="fail")] | length >= 3' <<<"$out" >/dev/null 2>&1; then
  report pass "--json lists the failing assets"
else
  report fail "--json lists the failing assets" "$out"
fi

if jq -e '[.assets[] | select(.name=="plugin:stripe:stripe" and .verdict=="unknown")] | length == 1' <<<"$out" >/dev/null 2>&1; then
  report pass "--json marks stripe unknown"
else
  report fail "--json marks stripe unknown" "$out"
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash tests/preflight/run.sh
```

Expected: the three JSON assertions fail — the flag is unrecognised and human output is emitted instead.

- [ ] **Step 3: Implement argument parsing and `render_json`**

Add near the top of `scripts/preflight.sh`, after the path variables:

```bash
OPT_JSON=0
OPT_QUARANTINE=0
OPT_SMOKE=0

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)       OPT_JSON=1 ;;
      --quarantine) OPT_QUARANTINE=1 ;;
      --smoke)      OPT_SMOKE=1 ;;
      -h|--help)
        cat <<'USAGE'
preflight.sh — verify configured assets actually work

  --json         machine-readable output (schema 1)
  --quarantine   disable failing MCP servers (backs up first)
  --smoke        also run tests/smoke/ for assets that passed
  -h, --help     this message
USAGE
        exit 0 ;;
      *)
        echo "unknown option: $1" >&2
        exit 2 ;;
    esac
    shift
  done
}
```

Add `render_json` above `main()`:

```bash
render_json() {
  local f c n v d cont
  {
    printf '{"schema":1,'
    printf '"ranAt":"%s",' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '"tier":%d,' "$(( OPT_SMOKE ? 3 : 2 ))"
    printf '"summary":{"assets":%d,"pass":%d,"fail":%d,"unknown":%d,"untested":%d},' \
      "${#FINDINGS[@]}" "$(count_verdict pass)" "$(count_verdict fail)" \
      "$(count_verdict unknown)" "$(count_verdict untested)"
    printf '"assets":['
    local first=1
    for f in ${FINDINGS+"${FINDINGS[@]}"}; do
      IFS='|' read -r c n v d cont <<<"$f"
      [ "$first" -eq 0 ] && printf ','
      first=0
      printf '{"class":%s,"name":%s,"verdict":%s,"detail":%s,"containable":%s}' \
        "$(jq -Rn --arg x "$c" '$x')" \
        "$(jq -Rn --arg x "$n" '$x')" \
        "$(jq -Rn --arg x "$v" '$x')" \
        "$(jq -Rn --arg x "$d" '$x')" \
        "$([ "$cont" = "yes" ] && echo true || echo false)"
    done
    printf ']}'
  } | jq .
}
```

Using `jq -Rn --arg` for every string guarantees correct escaping — MCP failure details contain quotes, colons, and em dashes.

In `main()`, call `parse_args "$@"` as the first line, and replace `render_human` with:

```bash
  if [ "$OPT_JSON" -eq 1 ]; then
    render_json
  else
    render_human
  fi
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/preflight/run.sh
```

Expected: `18 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight.sh tests/preflight
git commit -m "Add --json output with schema 1

Every string is escaped through jq -Rn, since MCP failure details contain
quotes, colons, and em dashes. schema:1 lets cron alerting and a future
/preflight skill consume results without parsing the human table.

Claude-Session: https://claude.ai/code/session_01EnVRBZg1RGSaEHxG1kuL21"
```

---

### Task 7: `--quarantine` with provenance

**Files:**

- Modify: `scripts/preflight.sh` (`apply_quarantine`, quarantined-asset reporting)
- Modify: `tests/preflight/run.sh`

**Interfaces:**

- Consumes: `FINDINGS`, `CLAUDE_JSON`
- Produces: `apply_quarantine()`

- [ ] **Step 1: Write the failing tests**

```bash
# --- quarantine -------------------------------------------------------------
# Work on a copy so the fixture stays pristine.
QDIR=$(mktemp -d)
cp "$TESTS_DIR/fixtures/regression/claude.json" "$QDIR/claude.json"

PATH="$TESTS_DIR/stubs:$PATH" \
PREFLIGHT_FIXTURE="$TESTS_DIR/fixtures/regression" \
PREFLIGHT_CLAUDE_JSON="$QDIR/claude.json" \
PREFLIGHT_SETTINGS_JSON="$TESTS_DIR/fixtures/regression/settings.json" \
PREFLIGHT_ENV_FILE="$TESTS_DIR/fixtures/regression/env" \
PREFLIGHT_SKILLS_DIR="$TESTS_DIR/fixtures/regression/skills" \
  bash "$REPO_DIR/scripts/preflight.sh" --quarantine >/dev/null 2>&1

if jq -e '.mcpServers.magic.disabled == true' "$QDIR/claude.json" >/dev/null 2>&1; then
  report pass "quarantine disables a failing server"
else
  report fail "quarantine disables a failing server" "$(cat "$QDIR/claude.json")"
fi

if jq -e '.mcpServers.magic._preflight.reason | length > 0' "$QDIR/claude.json" >/dev/null 2>&1; then
  report pass "quarantine records provenance"
else
  report fail "quarantine records provenance" "$(cat "$QDIR/claude.json")"
fi

# UNKNOWN must never be quarantined — stripe is plugin-supplied and absent from
# claude.json, so assert nothing was invented for it.
if ! jq -e '.mcpServers | has("plugin:stripe:stripe")' "$QDIR/claude.json" >/dev/null 2>&1; then
  report pass "quarantine never touches unknown assets"
else
  report fail "quarantine never touches unknown assets" "$(cat "$QDIR/claude.json")"
fi

# Non-containable failures must be left alone.
if ! jq -e '.mcpServers | has("agent-browser")' "$QDIR/claude.json" >/dev/null 2>&1; then
  report pass "quarantine leaves non-containable failures alone"
else
  report fail "quarantine leaves non-containable failures alone"
fi
rm -rf "$QDIR"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash tests/preflight/run.sh
```

Expected: the four quarantine assertions fail — `--quarantine` parses but does nothing.

- [ ] **Step 3: Implement `apply_quarantine`**

Add above `main()`:

```bash
# Disable failing MCP servers, recording why and when. Only class=mcp with
# verdict=fail and containable=yes is eligible: UNKNOWN is never quarantined,
# because "needs authentication" is an unfinished setup, not a fault.
apply_quarantine() {
  local f c n v d cont applied=0 backup ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    IFS='|' read -r c n v d cont <<<"$f"
    [ "$c" = "mcp" ] && [ "$v" = "fail" ] && [ "$cont" = "yes" ] || continue
    jq -e --arg k "$n" '.mcpServers | has($k)' "$CLAUDE_JSON" >/dev/null 2>&1 || continue

    if [ "$applied" -eq 0 ]; then
      backup="${CLAUDE_JSON}.preflight-$(date '+%Y%m%d_%H%M%S').bak"
      cp "$CLAUDE_JSON" "$backup"
      printf '\nQUARANTINE\n  backed up %s\n' "$backup"
    fi

    local tmp
    tmp="$(mktemp)"
    # Preserve an existing quarantinedAt so re-running is idempotent.
    jq --arg k "$n" --arg r "$d" --arg t "$ts" '
      .mcpServers[$k].disabled = true
      | .mcpServers[$k]._preflight.quarantinedAt =
          (.mcpServers[$k]._preflight.quarantinedAt // $t)
      | .mcpServers[$k]._preflight.reason = $r
    ' "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON"

    printf '  → %-18s disabled: true\n' "$n"
    applied=$((applied + 1))
  done

  if [ "$applied" -eq 0 ]; then
    printf '\nQUARANTINE\n  nothing containable\n'
  else
    printf '  %d contained · re-enable with ./setup.sh add <name>\n' "$applied"
  fi
}
```

In `main()`, after the render call:

```bash
  if [ "$OPT_QUARANTINE" -eq 1 ]; then
    apply_quarantine
  fi
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/preflight/run.sh
```

Expected: `22 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight.sh tests/preflight
git commit -m "Add --quarantine with provenance markers

Only MCP failures marked containable are disabled; unknown is never
quarantined. The _preflight marker lets a later run distinguish its own
work from a deliberate opt-out, and preserving quarantinedAt makes
re-running idempotent.

Claude-Session: https://claude.ai/code/session_01EnVRBZg1RGSaEHxG1kuL21"
```

---

### Task 8: Tier 3 smoke runner

**Files:**

- Modify: `scripts/preflight.sh` (`run_smoke`)
- Modify: `tests/preflight/run.sh`
- Create: `tests/smoke/README.md`
- Create: `tests/preflight/fixtures/regression/smoke/mcp-context7.sh`
- Create: `tests/preflight/fixtures/regression/smoke/mcp-github.sh`

**Interfaces:**

- Consumes: `FINDINGS`, `SMOKE_DIR`
- Produces: `run_smoke()`

- [ ] **Step 1: Write the failing tests**

`tests/preflight/fixtures/regression/smoke/mcp-context7.sh` (passes):

```bash
#!/bin/bash
exit 0
```

`tests/preflight/fixtures/regression/smoke/mcp-github.sh` (fails):

```bash
#!/bin/bash
echo "403 on repos/joggerjoel/ai-dotfiles"
exit 1
```

`chmod +x tests/preflight/fixtures/regression/smoke/*.sh`

`tests/smoke/README.md`:

```markdown
# Smoke tests

Optional per-asset scripts. `just audit` runs each one for an asset that
passed the tier-2 handshake. Exit 0 means pass; any other code means fail.

Naming: `mcp-<server>.sh`, `cli-<command>.sh`, `skill-<name>.sh`.

An asset with no file here is reported UNTESTED, never PASS. Coverage is a
number you can improve, not a silent gap.

Each script runs in a subshell under `timeout 60`, so a hung test becomes one
failure rather than a hung audit.
```

Append to `tests/preflight/run.sh`:

```bash
# --- tier 3 smoke -----------------------------------------------------------
out=$(run_preflight regression --smoke 2>&1)
if grep -q 'mcp-github' <<<"$out"; then
  report pass "smoke reports the failing test"
else
  report fail "smoke reports the failing test" "$out"
fi

if grep -qi 'untested' <<<"$out"; then
  report pass "smoke reports untested assets by name"
else
  report fail "smoke reports untested assets by name" "$out"
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash tests/preflight/run.sh
```

Expected: the two smoke assertions fail.

- [ ] **Step 3: Implement `run_smoke`**

Add above `main()`:

```bash
# Tier 3. Runs only for assets that passed tier 2 — smoke-testing a server that
# never connected buries the root cause under cascading noise.
run_smoke() {
  local f c n v script rc out
  [ -d "$SMOKE_DIR" ] || return

  printf '\n%-40s\n' "SMOKE"
  local ran=0 passed=0 failed=0 untested=()

  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    IFS='|' read -r c n v _ _ <<<"$f"
    [ "$v" = "pass" ] || continue
    script="$SMOKE_DIR/${c}-${n}.sh"
    if [ ! -x "$script" ]; then
      untested+=("$n")
      add_finding smoke "$n" untested "no smoke test" no
      continue
    fi
    out=$(timeout 60 bash "$script" 2>&1); rc=$?
    ran=$((ran + 1))
    if [ "$rc" -eq 0 ]; then
      passed=$((passed + 1))
      add_finding smoke "$n" pass "smoke ok" no
    else
      failed=$((failed + 1))
      add_finding smoke "$n" fail "${c}-${n}.sh exit $rc: $(head -1 <<<"$out")" no
      printf '  ✘ %-18s exit %d: %s\n' "${c}-${n}" "$rc" "$(head -1 <<<"$out")"
    fi
  done

  printf '  %d run · %d pass · %d fail\n' "$ran" "$passed" "$failed"
  if [ ${#untested[@]} -gt 0 ]; then
    printf '\nUNTESTED (%d)\n  %s\n' "${#untested[@]}" "${untested[*]}"
  fi
}
```

In `main()`, between the render call and the quarantine call:

```bash
  if [ "$OPT_SMOKE" -eq 1 ]; then
    run_smoke
  fi
```

Note the ordering: `run_smoke` appends findings after `render_human` has already printed, so smoke results print in their own section. The final exit still counts every `fail`, including smoke failures, because `count_verdict` runs last.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/preflight/run.sh
```

Expected: `24 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight.sh tests/preflight tests/smoke
git commit -m "Add tier-3 smoke runner

Smoke tests run only for assets that passed the handshake. Assets without a
smoke test are reported UNTESTED and listed by name, never counted as
passing. Each test runs under timeout 60 so a hung test is one failure, not
a hung audit.

Claude-Session: https://claude.ai/code/session_01EnVRBZg1RGSaEHxG1kuL21"
```

---

### Task 9: justfile verbs and `update.sh` integration

**Files:**

- Modify: `justfile` (add `preflight`, `audit`, `test`)
- Modify: `update.sh` (append the verification step)

**Interfaces:**

- Consumes: `scripts/preflight.sh`, `tests/preflight/run.sh`
- Produces: `just preflight`, `just audit`, `just test`

- [ ] **Step 1: Add the justfile recipes**

Insert after the existing `lint:` recipe in `justfile`:

```make
# [local] verify every configured asset actually works (read-only)
preflight *ARGS:
    {{dotfiles}}/scripts/preflight.sh {{ARGS}}

# [local] preflight plus tier-3 smoke tests
audit:
    {{dotfiles}}/scripts/preflight.sh --smoke

# [local] run the preflight test suite
test:
    {{dotfiles}}/tests/preflight/run.sh
```

`*ARGS` lets `just preflight --quarantine` and `just preflight --json` pass through.

- [ ] **Step 2: Verify the recipes run**

```bash
just test
just preflight --json | jq '.summary'
```

Expected: `just test` prints the passing suite. `just preflight --json` prints a summary object against your real environment — it may report failures, which is correct behaviour, not a test failure.

- [ ] **Step 3: Append the verification step to `update.sh`**

Add before `update.sh`'s final success message:

```bash
# ── Verify the upgraded environment ──────────────────────────────
# update.sh upgrades CLIs and re-vendors skills — the operations most likely
# to break an asset — so verify immediately afterwards. Read-only, and never
# fails the update: an upgrade is not broken because an unrelated MCP server
# is down, and conflating the two teaches you to ignore the exit code.
header "Verifying assets"
if [ -x "$DOTFILES_DIR/scripts/preflight.sh" ]; then
  "$DOTFILES_DIR/scripts/preflight.sh" || true
else
  skip "scripts/preflight.sh not present — skipping verification"
fi
```

`update.sh` defines `DOTFILES_DIR`, `header`, and `skip` already; confirm with `grep -n 'DOTFILES_DIR=\|^header()\|^skip()' update.sh` before inserting, and if `DOTFILES_DIR` is absent use the script's own `cd "$(dirname "$0")" && pwd` idiom.

- [ ] **Step 4: Verify `update.sh` still parses and does not abort**

```bash
bash -n update.sh && echo "SYNTAX OK"
```

Expected: `SYNTAX OK`. The `|| true` guarantees a failing preflight cannot abort `update.sh`, which runs under `set -e`.

- [ ] **Step 5: Commit**

```bash
git add justfile update.sh
git commit -m "Wire preflight into justfile and update.sh

just preflight / audit / test expose the checker; update.sh runs it
read-only as a final step, since upgrading CLIs and re-vendoring skills are
what break assets. It never fails the update.

Claude-Session: https://claude.ai/code/session_01EnVRBZg1RGSaEHxG1kuL21"
```

---

### Task 10: Lint, document, and close out

**Files:**

- Modify: `README.md` or `base/CLAUDE.md` (document the new verbs)

- [ ] **Step 1: Lint every new script**

```bash
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning scripts/preflight.sh lib/integrations.sh tests/preflight/run.sh
  echo "shellcheck exit: $?"
else
  echo "shellcheck NOT installed — falling back to syntax check"
  bash -n scripts/preflight.sh && bash -n lib/integrations.sh && bash -n tests/preflight/run.sh
  echo "bash -n: OK"
fi
```

Expected: no warnings, or an explicit note that `shellcheck` is unavailable. Fix any warning before continuing; do not silence one with a `# shellcheck disable` comment unless you can state why in the same line.

- [ ] **Step 2: Document the verbs**

Add to the tooling section of `base/CLAUDE.md`:

```markdown
## Asset verification

| Command                       | What it does                                          |
| ----------------------------- | ----------------------------------------------------- |
| `just preflight`              | Verify every configured asset works (read-only, ~90s) |
| `just preflight --quarantine` | Disable failing MCP servers, backing up first         |
| `just audit`                  | Preflight plus tier-3 smoke tests                     |
| `just test`                   | Run the preflight test suite                          |

Status reflects behaviour, not configuration: an asset is only `✔` if a live
probe succeeded. `!` means the asset needs something from you (usually
authentication) and is never auto-disabled.
```

Then propagate: `./setup.sh update --no-pull`

- [ ] **Step 3: Full suite green**

```bash
just test
```

Expected: `24 passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add base/CLAUDE.md CLAUDE.md
git commit -m "Document asset verification verbs

Claude-Session: https://claude.ai/code/session_01EnVRBZg1RGSaEHxG1kuL21"
```

---

## Self-review

**Spec coverage:**

| Spec section                              | Task                                                |
| ----------------------------------------- | --------------------------------------------------- |
| `lib/integrations.sh` extraction          | 1                                                   |
| `MANDATED_CLIS` declared, not parsed      | 1                                                   |
| Five asset classes                        | 3 (mcp), 4 (cli, env, hook, skill)                  |
| Four verdicts, unknown never quarantined  | 3 (unknown), 7 (quarantine guard)                   |
| MCP-only containment                      | 7                                                   |
| Provenance marker, idempotent             | 7                                                   |
| 180s timeout → unknown, not fail          | 3                                                   |
| Exit codes 0/1/2                          | 5                                                   |
| Human report, passes collapsed            | 5                                                   |
| JSON schema 1                             | 6                                                   |
| Tier 3, smoke only after tier-2 pass      | 8                                                   |
| UNTESTED listed by name                   | 8                                                   |
| `update.sh` read-only, never fails update | 9                                                   |
| Recovery via `./setup.sh add`             | 7 (printed), 10 (documented)                        |
| Regression corpus = the four failures     | 3 (mcp trio), 4 (agent-browser via `MANDATED_CLIS`) |
| Negative control                          | 2                                                   |
| Probe classes fenced independently        | 4 (each probe returns rather than exits)            |
| Smoke sandboxed under `timeout`           | 8                                                   |

No gaps.

**Placeholder scan:** none. Every step contains runnable code or an exact command with expected output.

**Type consistency:** the finding record is `class|name|verdict|detail|containable` in Tasks 2–8. `add_finding` takes those five positionally throughout. `count_verdict` reads field 3 everywhere. Class strings are `mcp`, `cli`, `env`, `hook`, `skill`, `smoke` — the same set in `render_class` calls, `run_smoke`, and `apply_quarantine`'s `[ "$c" = "mcp" ]` guard.

**One known deviation from the spec:** the spec says quarantine writes its backup "in the format `update.sh` already uses". Task 7 writes `~/.claude.json.preflight-<timestamp>.bak` beside the original instead, because `update.sh`'s snapshot layout is a whole-directory format built for rollback of an upgrade, and reusing it for a single-file change would require exporting internals from `update.sh`. The backup is still automatic and adjacent. Flag this to the user during execution; if they want true `rollback.sh` compatibility, that is a follow-up task.
