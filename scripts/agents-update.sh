#!/bin/bash
set -uo pipefail

# ─────────────────────────────────────────────────────────────────
# agents-update.sh — upgrade the sibling agent CLIs, when installed:
#   codex (OpenAI), cursor-agent (Cursor), opencode, gemini (Google),
#   agy (Google Antigravity), pi (Earendil),
#   grok (xAI), kimi (Moonshot Kimi Code),
#   cortex (Snowflake Cortex Code), headroom (context-optimization proxy),
#   skillspector (NVIDIA agent-skill security scanner).
# Plus a COMPANION CLI section at the end of the registry: tools that are
# not agents at all but belong to an installed plugin/skill — claude-mem's
# repair CLI today. They ride here for reach, not because they are agents;
# see that block for why, and who actually owns them.
# Also reports (but never updates) the 9router gateway — a Docker
# service on the fleet, not a local CLI; see the block at the bottom.
#
# Single source of truth for "update every agent CLI besides claude, plus
# the companion CLIs the plugin stack depends on": called by ./update.sh
# locally and by ansible-ai/update.yml on the fleet. A failed upgrade
# warns and moves on to the next; exits non-zero if any upgrade failed.
# Missing CLIs: interactive runs get an install offer (y/N, default no);
# unattended runs (Ansible, cron) skip them silently.
#
# Where a latest version is resolvable without installing (npm- and
# brew-backed CLIs), it is checked first and the upgrade is skipped
# outright when already current — so the fleet stops reinstalling
# packages that haven't moved.
#
# Interactive runs get a prompt ONLY for a CLI with a known-newer
# version: [U]pgrade/[P]in/[s]kip, default upgrade. Installer-only
# CLIs (codex, cursor-agent, cortex, opencode, kimi, mel) can't be
# checked without installing, so they never prompt — they just
# upgrade, as they always did. Upgrade/skip are one-off answers;
# nothing is recorded. Only [P]in persists, via the state file pin.sh
# manages, and it holds across every future run — interactive or
# unattended — until `pin.sh remove <name>`. Pin ahead of time with
# pin.sh (or `setup.sh pin add <name>`) to hold back a CLI that never
# prompts, or to have an unattended host converge on a pinned roster.
#
# Deliberately NOT `set -e` — one broken installer must not block
# the remaining CLIs; failures are collected and reported instead.
# ─────────────────────────────────────────────────────────────────

# Colors only on a terminal — Ansible captures this output, and ANSI
# escapes would garble the per-host report.
if [ -t 1 ]; then
  BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'
else
  BOLD=""; DIM=""; GREEN=""; YELLOW=""; RESET=""
fi
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
skip() { echo -e "  ${DIM}○ $1${RESET}"; }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }

# npm-installed CLIs (gemini) need node on PATH in non-login shells.
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# Pin/unpin state (is_pinned/pin_cli/unpin_cli) lives in pin.sh, which
# is also runnable standalone to set up pins ahead of an unattended
# run — see pin.sh's header.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/pin.sh"

CURL_RETRY="--retry 5 --retry-delay 2 --retry-connrefused"
FAILED=""
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

# Prompt only when a human is attached — Ansible and cron runs must
# stay unattended, so missing CLIs are skipped there (unless
# AGENTS_AUTO_INSTALL=1, which the fleet playbook sets so the CLI
# roster converges on hosts provisioned before a CLI was added).
INTERACTIVE="no"
[ -t 0 ] && [ -e /dev/tty ] && INTERACTIVE="yes"

# A hung vendor updater must not stall the whole fleet play.
RUN_TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then RUN_TIMEOUT="timeout 300"
elif command -v gtimeout >/dev/null 2>&1; then RUN_TIMEOUT="gtimeout 300"; fi

# offer_install <name> <install command>
# Interactive runs get a y/N offer to install a missing CLI;
# AGENTS_AUTO_INSTALL=1 installs without asking; anything else
# (no tty, no install command) just reports the skip.
offer_install() {
  local name="$1" cmd="${2:-}" answer="" ver=""
  if [ -z "$cmd" ]; then
    skip "$name not installed"
    return 0
  fi
  if [ "${AGENTS_AUTO_INSTALL:-0}" = "1" ]; then
    answer="y"
  elif [ "$INTERACTIVE" = "yes" ]; then
    printf "  ${DIM}○${RESET} %s not installed — install it? [y/N] " "$name"
    IFS= read -r answer </dev/tty || answer=""   # EOF-tolerant
  else
    skip "$name not installed"
    return 0
  fi
  case "$answer" in
    y | Y | yes | YES) ;;
    *) skip "$name skipped"; return 0 ;;
  esac
  if $RUN_TIMEOUT bash -c "$cmd" >"$LOG" 2>&1; then
    command -v "$name" >/dev/null 2>&1 && ver="$("$name" --version 2>/dev/null | head -1)"
    ok "$name installed${ver:+ (${ver})}"
  else
    warn "$name install failed — last output:"
    tail -n 5 "$LOG" | sed 's/^/      /'
    FAILED="$FAILED $name"
  fi
}

# Best-effort "what's the latest version" lookups. Never required —
# a lookup that fails or comes back empty just leaves the CLI's
# latest version unknown, which is a reportable state, not an error.
npm_latest() { command -v npm >/dev/null 2>&1 && npm view "$1" version 2>/dev/null; }
brew_latest() {
  command -v brew >/dev/null 2>&1 || return 0
  brew info "$1" 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1
}

# ── Wave structure ───────────────────────────────────────────────
# This runs in two passes over the same roster, because inspecting
# and mutating want different things from you.
#
#   Wave 1 (survey)  Read-only. Resolves every CLI's installed and
#                    available version and prints the table. Nothing
#                    is installed, so the full picture is on screen
#                    BEFORE the first question — you can see that
#                    three CLIs are current and one moved, instead of
#                    deciding on #1 with no idea what #2..#12 hold.
#   Wave 2 (apply)   Mutating. Per CLI: obey pin.sh's config if it
#                    has an entry, otherwise ask (when a human is
#                    attached) or upgrade (when not).
#
# register_cli <name> <binary path or command name> <upgrade command> [install command] [latest-version command]
# Registration is pure data — it must not print or mutate, or wave 1
# would no longer be a clean survey. "%BIN%" in the upgrade command
# is replaced during wave 2 with the RESOLVED binary path, so a CLI
# found outside ~/.local/bin upgrades itself rather than a hardcoded
# path that doesn't exist.
CLI_NAME=(); CLI_BIN=(); CLI_CMD=(); CLI_INSTALL=(); CLI_LATEST_CMD=(); CLI_BLOCKED=()
register_cli() {
  CLI_NAME+=("$1"); CLI_BIN+=("$2"); CLI_CMD+=("$3")
  CLI_INSTALL+=("${4:-}"); CLI_LATEST_CMD+=("${5:-}"); CLI_BLOCKED+=("")
}
# A CLI present but unupgradable here (locked keychain, no package
# manager). Registered so the survey still reports it and says why.
block_cli() {
  CLI_NAME+=("$1"); CLI_BIN+=(""); CLI_CMD+=(""); CLI_INSTALL+=("")
  CLI_LATEST_CMD+=(""); CLI_BLOCKED+=("$2")
}

# apply_cli <index> — wave 2's per-CLI mutation.
apply_cli() {
  local i="$1"
  local name="${CLI_NAME[$i]}" bin="${RES_BIN[$i]}" cmd="${CLI_CMD[$i]}"
  local before="${RES_CUR[$i]}" latest="${RES_LATEST[$i]}" status="${RES_STATUS[$i]}"
  local action after="" choice=""

  # Already fully reported by the survey — saying it twice would bury
  # the lines that represent actual work.
  case "$status" in
    blocked | current) return 0 ;;
    missing) offer_install "$name" "${CLI_INSTALL[$i]}"; return 0 ;;
  esac

  action="$(get_action "$name")"
  case "$action" in
    pin)  skip "$name: pinned at ${before:-current version} — clear with: pin.sh remove $name"; return 0 ;;
    auto) ;;  # configured to always upgrade — no question
    *)
      # Unconfigured. Ask only when a human is attached AND we can
      # show a concrete newer version; an unattended run, or one
      # where "latest" is unknowable, takes the default and upgrades.
      if [ "$INTERACTIVE" = "yes" ] && [ "$status" = "outdated" ]; then
        printf "  %s: %s → %s — [U]pgrade once/[A]lways/[P]in/[s]kip? [U/a/p/s] " \
          "$name" "${before:-?}" "$latest"
        IFS= read -r choice </dev/tty || choice=""
        case "$choice" in
          a | A) set_action "$name" auto; ok "$name: will always upgrade from now on" ;;
          p | P) set_action "$name" pin; skip "$name pinned at ${before:-current version}"; return 0 ;;
          s | S) skip "$name skipped this run"; return 0 ;;
          *) ;; # default (bare Enter included): upgrade once, record nothing
        esac
      fi
      ;;
  esac

  cmd="${cmd//%BIN%/$bin}"
  if $RUN_TIMEOUT bash -c "$cmd" >"$LOG" 2>&1; then
    after="$("$bin" --version 2>/dev/null | head -1)"
    if [ -n "$after" ] && [ "$after" = "$before" ]; then
      ok "$name: already latest (${after})"
    else
      ok "$name: ${before:-?} → ${after:-?}"
    fi
  else
    warn "$name upgrade failed — last output:"
    tail -n 5 "$LOG" | sed 's/^/      /'
    FAILED="$FAILED $name"
  fi
}

# CODEX_NON_INTERACTIVE=1 answers "no" to the installer's tty prompts
# ("Start Codex now?") — otherwise it grabs /dev/tty, and launching
# Codex makes the launch's exit status masquerade as an install failure.
# The installer doubles as the updater.
CODEX_INSTALL="curl $CURL_RETRY -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh"
register_cli "codex" "$HOME/.local/bin/codex" "$CODEX_INSTALL" "$CODEX_INSTALL"

# cursor-agent needs the macOS login keychain, which is locked over
# SSH — a doomed attempt would just pollute the report every run.
if [ "$(uname -s)" = "Darwin" ] && [ -n "${SSH_CONNECTION:-}" ] \
   && ! security show-keychain-info >/dev/null 2>&1; then
  block_cli "cursor-agent" "login keychain locked over SSH — update from a local session"
else
  register_cli "cursor-agent" "$HOME/.local/bin/cursor-agent" \
    "\"%BIN%\" update" \
    "curl $CURL_RETRY -fsSL https://cursor.com/install | bash"
fi

# https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-cli
# NON_INTERACTIVE + SKIP_PATH_PROMPT: the installer otherwise prompts
# "add .local/bin to PATH? [y/N]" on /dev/tty and dies without one.
register_cli "cortex" "$HOME/.local/bin/cortex" \
  "\"%BIN%\" update" \
  "curl $CURL_RETRY -LsS https://ai.snowflake.com/static/cc-scripts/install.sh | NON_INTERACTIVE=1 SKIP_PATH_PROMPT=1 sh"

# opencode's installer dir varies between versions.
OPENCODE_INSTALL="curl $CURL_RETRY -fsSL https://opencode.ai/install | bash"
OPENCODE_BIN=""
for p in "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode"; do
  [ -x "$p" ] && { OPENCODE_BIN="$p"; break; }
done
[ -z "$OPENCODE_BIN" ] && OPENCODE_BIN="$(command -v opencode 2>/dev/null || true)"
# Registering the bare name when nothing resolved lets wave 1 report it
# as missing and wave 2 offer the install — same path as every other CLI.
register_cli "opencode" "${OPENCODE_BIN:-opencode}" \
  "\"%BIN%\" upgrade || $OPENCODE_INSTALL" "$OPENCODE_INSTALL"

# gemini is npm-installed on the fleet but may be brew-managed locally;
# upgrading the wrong way would leave two copies fighting over PATH.
# Fresh installs prefer brew when it exists, npm otherwise.
GEMINI_UPGRADE="npm install -g @google/gemini-cli@latest"
GEMINI_INSTALL="npm install -g @google/gemini-cli@latest"
GEMINI_LATEST="npm_latest @google/gemini-cli"
if command -v brew >/dev/null 2>&1; then
  GEMINI_INSTALL="brew install gemini-cli"
  if brew list --formula gemini-cli >/dev/null 2>&1; then
    GEMINI_UPGRADE="brew upgrade gemini-cli"
    GEMINI_LATEST="brew_latest gemini-cli"
  fi
fi
register_cli "gemini" "gemini" "$GEMINI_UPGRADE" "$GEMINI_INSTALL" "$GEMINI_LATEST"

# agy (Google Antigravity) — a flat native binary, not a package. The
# bootstrapper resolves a per-platform manifest, verifies the payload's
# published sha512 and drops the binary in ~/.local/bin/agy.
#
# Install and upgrade are DIFFERENT commands here, unlike codex where the
# installer doubles as the updater. Re-running the bootstrapper over an
# existing binary is a deliberate no-op: it prints "'agy' is already
# installed" and exits 0, so wiring it as the upgrade path would report a
# successful upgrade on every run while the version never moved.
# `agy update` is the real updater — it exits 0 and says "already on the
# latest version" when there is nothing to do, which is what wave 2 wants.
# %BIN% so a binary installed outside ~/.local/bin updates itself.
#
# No latest-version lookup: the manifest is keyed by platform and the CLI
# also self-updates in the background during normal runs, so "latest" is
# not cheaply resolvable from here. Like the other installer-only CLIs it
# therefore never prompts — it just upgrades. Pin it with pin.sh to hold.
AGY_INSTALL="curl $CURL_RETRY -fsSL https://antigravity.google/cli/install.sh | bash"
register_cli "agy" "$HOME/.local/bin/agy" "\"%BIN%\" update" "$AGY_INSTALL"

# pi (Earendil Pi coding agent) — npm global, MIT. Vendor documents
# --ignore-scripts on install; pi has its own updater (`pi update self`),
# so prefer that and fall back to npm if the self-update path fails.
# The npm registry version is a reasonable stand-in for "latest" even
# on the self-update path — both track the same upstream releases.
PI_INSTALL="npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
register_cli "pi" "pi" "\"%BIN%\" update self || $PI_INSTALL" "$PI_INSTALL" "npm_latest @earendil-works/pi-coding-agent"

# grok (official xAI Grok CLI) — npm global. The @xai-official/grok package
# is the one firstmate's grok harness targets (grok --always-approve); the
# many third-party grok-cli packages are NOT interchangeable.
GROK_INSTALL="npm install -g @xai-official/grok@latest"
register_cli "grok" "grok" "$GROK_INSTALL" "$GROK_INSTALL" "npm_latest @xai-official/grok"

# kimi (Kimi Code CLI, Moonshot) — installs to ~/.kimi-code/bin, which is off
# PATH in the non-login shells Ansible and cron use, so resolve it by absolute
# path first (update_cli falls back to `command -v`). It ships a native
# `upgrade` subcommand; the official installer is the fallback and doubles as
# the installer for a missing host. That installer pulls a ~151 MB binary and
# verifies it against a SHA-256 from the release manifest.
# NB: MoonshotAI/kimi-cli (the older Python CLI) is a DIFFERENT, wound-down
# project — this is kimi-code, its successor.
KIMI_INSTALL="curl $CURL_RETRY --proto '=https' --tlsv1.2 -fsSL https://code.kimi.com/kimi-code/install.sh | bash"
register_cli "kimi" "$HOME/.kimi-code/bin/kimi" "\"%BIN%\" upgrade || $KIMI_INSTALL" "$KIMI_INSTALL"

# mel (openmel.dev) — agentic terminal; a desktop app whose binary is also a
# working CLI (`mel --version` answers), so it belongs in this roster.
# It ships as a plain archive from S3: no package manager, no version endpoint,
# no release feed. Nothing to ask "is this current?", so the wrapper caches the
# object's ETag and skips the download when it has not moved — without that,
# every fleet pass would re-pull 27-45 MB per host for an unchanged build.
# macOS is a .app bundle (symlinked onto PATH); Linux is x86_64 only and the
# wrapper stops with a clear message on anything else.
MEL_INSTALL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-mel.sh"
register_cli "mel" "$HOME/.local/bin/mel" "$MEL_INSTALL" "$MEL_INSTALL"

# just (command runner — the justfile launchpad). Same split as gemini:
# brew-managed where brew manages it, otherwise the official installer,
# which always fetches the latest prebuilt binary into ~/.local/bin — so
# install and upgrade are the same command on the Linux fleet.
# --force is required precisely BECAUSE install and upgrade are the same
# command here: without it the installer aborts with "already exists" on
# every host that has just, so upgrades never land on the Linux fleet.
JUST_INSTALL="curl $CURL_RETRY --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --force --to \"\$HOME/.local/bin\""
JUST_UPGRADE="$JUST_INSTALL"
JUST_LATEST=""
if command -v brew >/dev/null 2>&1; then
  JUST_INSTALL="brew install just"
  if brew list --formula just >/dev/null 2>&1; then
    JUST_UPGRADE="brew upgrade just"
    JUST_LATEST="brew_latest just"
  fi
fi
register_cli "just" "just" "$JUST_UPGRADE" "$JUST_INSTALL" "$JUST_LATEST"

# headroom is a pipx- or uv-tool-managed python CLI; `headroom update`
# confirms on a tty, so drive the manager directly. Resolve both by
# absolute path — Ansible/cron shells are non-login, so brew's bin dir
# and ~/.local/bin may be off PATH. An already-running proxy keeps
# serving the old code after an upgrade — warn instead of restarting
# it, since other CLIs may be mid-stream through it.
resolve_tool() {
  local found p
  found="$(command -v "$1" 2>/dev/null || true)"
  if [ -z "$found" ]; then
    for p in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.cargo/bin"; do
      [ -x "$p/$1" ] && { found="$p/$1"; break; }
    done
  fi
  printf '%s' "$found"
}
PIPX="$(resolve_tool pipx)"
UV="$(resolve_tool uv)"

# pipx ≥1.8 shells out to `uv` when the venv was built with the uv
# backend, and it searches PATH itself — resolving pipx by absolute
# path isn't enough. Expose uv's dir; without uv, force the pip
# backend (pipx accepts it even for uv-built venvs).
if [ -n "$UV" ]; then
  PATH="$(dirname "$UV"):$PATH"
  export PATH
else
  export PIPX_DEFAULT_BACKEND=pip
fi

if [ -n "$UV" ] && [ -d "$HOME/.local/share/uv/tools/headroom-ai" ]; then
  # installed as a uv tool (hosts provisioned without pipx)
  register_cli "headroom" "$HOME/.local/bin/headroom" \
    "\"$UV\" tool upgrade headroom-ai" \
    "\"$UV\" tool install 'headroom-ai[all]'"
elif [ -n "$PIPX" ]; then
  register_cli "headroom" "$HOME/.local/bin/headroom" \
    "\"$PIPX\" upgrade headroom-ai" \
    "\"$PIPX\" install 'headroom-ai[all]'"
elif [ -n "$UV" ]; then
  register_cli "headroom" "$HOME/.local/bin/headroom" \
    "\"$UV\" tool upgrade headroom-ai" \
    "\"$UV\" tool install 'headroom-ai[all]'"
elif [ -x "$HOME/.local/bin/headroom" ]; then
  block_cli "headroom" "installed but neither pipx nor uv found — can't upgrade it"
else
  block_cli "headroom" "skipped (pipx/uv not available)"
fi

# skillspector scans agent skills for prompt injection, exfiltration and
# supply-chain risk before they get installed. Registered here, not just in
# setup.sh's ensure_dependencies, because that only runs on a full setup:
# ansible-ai/update.yml drives existing hosts through `setup.sh update` +
# this script, so a CLI absent from here never converges on the fleet.
#
# uv-only (no pipx branch): it ships as a git install, and pipx would resolve a
# different package. Registering it on a host that lacks it is safe — a missing
# CLI is reported, not installed, unless AGENTS_AUTO_INSTALL=1, so the fleet
# does not silently gain a scanner mid-update.
#
# No latest-version lookup: installed from a branch ref, so there is no
# published version to diff against. That leaves it "latest unknown", which
# upgrades every run — the documented behaviour for uncheckable CLIs.
if [ -n "$UV" ]; then
  register_cli "skillspector" "$HOME/.local/bin/skillspector" \
    "\"$UV\" tool upgrade skillspector" \
    "\"$UV\" tool install 'git+https://github.com/NVIDIA/skillspector.git'"
elif [ -x "$HOME/.local/bin/skillspector" ]; then
  block_cli "skillspector" "installed but uv not found — can't upgrade it"
else
  block_cli "skillspector" "skipped (uv not available)"
fi

# ── Companion CLIs (NOT agents) ──────────────────────────────────
# Tools that belong to an installed plugin or skill, not to a harness. They are
# registered in this file for one reason — reach: it is the only step that runs
# on every host (./update.sh locally, ansible-ai/update.yml on the fleet,
# provision-firstmate-worker.sh on a fresh worker), so a CLI absent from here
# never converges. Registration is NOT ownership: the asset is still classified
# as a plugin everywhere it matters — bootstrap-plugins.sh installs it from its
# marketplace, and lib/integrations.sh's PLUGIN_ASSETS is what probes whether it
# is actually doing its job. Nothing in this section is an AI CLI, and the
# roster at the top of this file must not list it as one.

# claude-mem — the memory PLUGIN's repair CLI, a SEPARATE npm package from the
# plugin that ships the skills, hooks and MCP server. Unregistered, it resolved
# only through `npx`, which stops to ask "Ok to proceed?" before downloading
# 13 MB — and the one moment you reach for `claude-mem restart` or `claude-mem
# doctor` is mid-outage, on a box that may be unattended, over a link that may
# be the thing that broke. Hit 2026-09-01: the observer had been failing for 9
# hours and the documented recovery command was itself not installed.
CLAUDE_MEM_INSTALL="npm install -g claude-mem@latest"
register_cli "claude-mem" "claude-mem" "$CLAUDE_MEM_INSTALL" "$CLAUDE_MEM_INSTALL" "npm_latest claude-mem"

# ── Wave 1: survey (read-only) ───────────────────────────────────
# Resolve and report every CLI before touching any of them.
echo -e "${BOLD}Sibling agent CLIs & plugin companions${RESET}"
RES_BIN=(); RES_CUR=(); RES_LATEST=(); RES_STATUS=()
NEED_ACTION="no"
for i in "${!CLI_NAME[@]}"; do
  name="${CLI_NAME[$i]}"; bin="${CLI_BIN[$i]}"; cur=""; latest=""; status=""
  if [ -n "${CLI_BLOCKED[$i]}" ]; then
    status="blocked"
  else
    [ -x "$bin" ] || bin="$(command -v "$bin" 2>/dev/null || true)"
    if [ -z "$bin" ]; then
      status="missing"
    else
      cur="$("$bin" --version 2>/dev/null | head -1)"
      # eval, not `bash -c` — the lookups are shell functions defined
      # above, and a subshell wouldn't have them.
      [ -n "${CLI_LATEST_CMD[$i]}" ] && latest="$(eval "${CLI_LATEST_CMD[$i]}" 2>/dev/null)"
      if [ -n "$latest" ] && [ -n "$cur" ] && [[ "$cur" == *"$latest"* ]]; then
        status="current"
      elif [ -n "$latest" ]; then
        status="outdated"
      else
        # No way to check without installing — the installer decides.
        status="unknown"
      fi
    fi
  fi
  RES_BIN+=("$bin"); RES_CUR+=("$cur"); RES_LATEST+=("$latest"); RES_STATUS+=("$status")

  case "$status" in
    blocked)  note="${CLI_BLOCKED[$i]}";        color="$DIM" ;;
    missing)  note="not installed";             color="$DIM" ;;
    current)  note="current";                   color="$GREEN" ;;
    outdated) note="→ ${latest} available";     color="$YELLOW" ;;
    unknown)  note="latest unknown";            color="$DIM" ;;
  esac
  # Policy rides on the same line — a CLI's version and whether it is
  # frozen are one fact, and splitting them doubles the table's height.
  pol="$(get_action "$name")"
  case "$pol" in
    pin)  poltag=" [pinned]" ;;
    auto) poltag=" [auto]" ;;
    *)    poltag="" ;;
  esac
  printf "  %-14s %-30s ${color}%s${RESET}${DIM}%s${RESET}\n" "$name" "$cur" "$note" "$poltag"

  case "$status" in
    current | blocked) ;;
    *) [ "$pol" = "pin" ] || NEED_ACTION="yes" ;;
  esac
done

# ── Wave 2: apply (mutating) ─────────────────────────────────────
# Only entries that represent real work reach this pass; pinned CLIs
# and anything already current were settled by the survey.
if [ "$NEED_ACTION" = "yes" ]; then
  echo
  echo -e "${BOLD}Updates${RESET}"
  for i in "${!CLI_NAME[@]}"; do
    apply_cli "$i"
  done
fi
HEADROOM_BIN="$HOME/.local/bin/headroom"
[ -x "$HEADROOM_BIN" ] || HEADROOM_BIN="$(command -v headroom 2>/dev/null || true)"
if [ -n "$HEADROOM_BIN" ]; then
  HEADROOM_PORT="${HEADROOM_PORT:-8787}"
  proxy_ver="$(curl -m 2 -fsS "http://127.0.0.1:${HEADROOM_PORT}/health" 2>/dev/null \
    | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
  cli_ver="$("$HEADROOM_BIN" --version 2>/dev/null | awk '{print $NF}')"
  if [ -n "$proxy_ver" ] && [ -n "$cli_ver" ] && [ "$proxy_ver" != "$cli_ver" ]; then
    # Whose proxy is lagging? A process of ours → restartable (the fleet
    # update does it via deploy-headroom-proxy.yml). No process of ours →
    # it's the Docker container from deploy-9router.yml, and a restart
    # won't help: the upstream image itself still ships the old version.
    # prox[y] keeps pgrep from matching its own command line.
    if pgrep -u "$(id -un)" -f 'headroom(\.cli)? prox[y]' >/dev/null 2>&1; then
      warn "headroom proxy on :${HEADROOM_PORT} still runs ${proxy_ver} — restart to load ${cli_ver}: systemctl --user restart headroom-proxy (or relaunch it)"
    else
      warn "headroom proxy on :${HEADROOM_PORT} runs ${proxy_ver} (Docker-managed, deploy-9router.yml) — upstream image lags the ${cli_ver} CLI; converges when a new image ships"
    fi
  fi
fi

# 9router is not a local CLI — it's a Docker service (decolua/9router) on
# the aorus fleet, bound to 127.0.0.1:20128 there. Status report only:
# reachable directly on a fleet host, or via an SSH tunnel
# (ssh -N -L 20128:127.0.0.1:20128 <host>) from elsewhere. Updating it
# means re-running ansible-ai/deploy-9router.yml — never from here, since
# other CLIs may be mid-stream through the gateway.
NINEROUTER_PORT="${NINEROUTER_PORT:-20128}"
nine_ver_json="$(curl -m 2 -fsS "http://127.0.0.1:${NINEROUTER_PORT}/api/version" 2>/dev/null)"
if [ -n "$nine_ver_json" ]; then
  nine_cur="$(printf '%s' "$nine_ver_json" | grep -o '"currentVersion":"[^"]*"' | cut -d'"' -f4)"
  nine_latest="$(printf '%s' "$nine_ver_json" | grep -o '"latestVersion":"[^"]*"' | cut -d'"' -f4)"
  if printf '%s' "$nine_ver_json" | grep -q '"hasUpdate":true'; then
    warn "9router gateway on :${NINEROUTER_PORT} runs ${nine_cur:-?} — ${nine_latest:-newer} available (re-run ansible-ai/deploy-9router.yml)"
  else
    ok "9router: gateway up on :${NINEROUTER_PORT} (${nine_cur:-?}, latest)"
  fi
elif curl -m 2 -fsS "http://127.0.0.1:${NINEROUTER_PORT}/api/health" >/dev/null 2>&1; then
  ok "9router: gateway up on :${NINEROUTER_PORT}"
else
  skip "9router: not reachable on :${NINEROUTER_PORT} — Docker service on the fleet; update via ansible-ai/deploy-9router.yml"
fi

# Pins persist and are easy to forget — months later a deliberately
# frozen CLI looks identical to one nobody has touched. Restate them
# on every run, unattended included: the survey marks each inline, but
# a fleet recap of 8 hosts is skimmed at the tail, not read in full.
PINS="$(list_pins)"
if [ -n "$PINS" ]; then
  echo
  echo -e "  ${DIM}Pinned, not upgraded: $(echo "$PINS" | tr '\n' ' ')${RESET}"
  echo -e "  ${DIM}Clear with: scripts/pin.sh remove <name>${RESET}"
fi

if [ -n "$FAILED" ]; then
  warn "Upgrades failed for:${FAILED}"
  exit 1
fi
