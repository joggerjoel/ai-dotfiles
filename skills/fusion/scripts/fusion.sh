#!/usr/bin/env bash
# fusion.sh — two-model fusion harness over headless agent CLIs.
#
#   opinion      "<prompt>"                      two models answer independently, side by side
#   fuse         "<prompt>" ["<merge-instr>"]    both answer, architect merges with attribution
#   autovalidate "<prompt>" [--rounds N]         validator writes an acceptance gate FIRST,
#                                                builder builds, gate runs, failures loop back
#
# Engines (override via env):
#   FUSION_ARCHITECT_CMD  default: claude   (headless: claude -p --output-format json)
#   FUSION_BUILDER_CMD    default: codex    (headless: codex exec -o <file>)
# Artifacts: $FUSION_DIR (default /tmp/fusion-harness)/run-<ts>/ — never inside the repo.
# Every run emits meta.json + report.html (self-contained; consensus/divergence cards).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ROOT="${FUSION_DIR:-/tmp/fusion-harness}"
ROUNDS=3

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

CMD="${1:-}"; shift || true
case "$CMD" in opinion|fuse|autovalidate) ;; -h|--help|"") usage ;; *) echo "unknown command: $CMD" >&2; usage 2 ;; esac
PROMPT="${1:-}"; shift || true
[ -n "$PROMPT" ] || { echo "need a prompt" >&2; usage 2; }
MERGE_INSTR=""
if [ "$CMD" = fuse ] && [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then MERGE_INSTR="$1"; shift; fi
while [ $# -gt 0 ]; do case "$1" in --rounds) ROUNDS="$2"; shift 2 ;; *) shift ;; esac; done

RUN_DIR="$RUN_ROOT/run-$(date +%Y%m%d_%H%M%S)-$CMD"
mkdir -p "$RUN_DIR"
printf '%s' "$PROMPT" > "$RUN_DIR/prompt.txt"

# ── engine wrappers ──────────────────────────────────────────────
# Each records: answer file, wall secs, tokens in/out + cost when the CLI reports them.

run_architect() { # $1=prompt-file $2=slug $3=permission-mode (default: default) $4=extra dir to allow writes in
  local pf="$1" slug="$2" mode="${3:-default}" extra_dir="${4:-}" t0 t1 rc
  local extra=()
  [ -n "$extra_dir" ] && extra=(--add-dir "$extra_dir")
  t0=$(date +%s)
  claude -p "$(cat "$pf")" --output-format json --permission-mode "$mode" "${extra[@]}" \
    > "$RUN_DIR/$slug.json" 2> "$RUN_DIR/$slug.err"
  rc=$?
  t1=$(date +%s)
  python3 - "$RUN_DIR/$slug.json" "$RUN_DIR/$slug.txt" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
open(sys.argv[2],"w").write(d.get("result",""))
u=d.get("usage",{})
print(json.dumps({"tokens_in":u.get("input_tokens"),"tokens_out":u.get("output_tokens"),
                  "cost":d.get("total_cost_usd"),"model":d.get("model") or d.get("modelUsage") and next(iter(d.get("modelUsage")),None)}))
PY
  echo "$((t1-t0)) $rc"
}

run_builder() { # $1=prompt-file $2=slug $3=sandbox (read-only|workspace-write)
  local pf="$1" slug="$2" sandbox="${3:-read-only}" t0 t1 rc
  t0=$(date +%s)
  codex exec -s "$sandbox" --ephemeral --skip-git-repo-check \
    -o "$RUN_DIR/$slug.txt" "$(cat "$pf")" > "$RUN_DIR/$slug.log" 2>&1
  rc=$?
  t1=$(date +%s)
  echo "$((t1-t0)) $rc"
}

# stats <slug> <secs> — best-effort tokens/cost pulled from engine output
arch_stats() { python3 - "$RUN_DIR/$1.json" <<'PY' 2>/dev/null || echo '{}'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print("{}"); raise SystemExit
u=d.get("usage",{})
print(json.dumps({"tokens_in":u.get("input_tokens"),"tokens_out":u.get("output_tokens"),"cost":d.get("total_cost_usd")}))
PY
}
build_stats() { python3 - "$RUN_DIR/$1.log" <<'PY' 2>/dev/null || echo '{}'
import re,sys
try: t=open(sys.argv[1]).read()
except Exception: print("{}"); raise SystemExit
m=re.search(r"[Tt]okens used:?\s*([\d,]+)",t)
print(__import__("json").dumps({"tokens_total":int(m.group(1).replace(",",""))} if m else {}))
PY
}

finish() { # $1=status ; writes meta.json, renders report, prints tail
  python3 "$SCRIPT_DIR/fusion_report.py" "$RUN_DIR" || true
  echo
  echo "── fusion artifacts: $RUN_DIR"
  [ -f "$RUN_DIR/report.html" ] && echo "── report:           $RUN_DIR/report.html"
}

meta_init() { # $1=status
  python3 - "$RUN_DIR" "$CMD" "$1" <<'PY'
import json,sys,os,datetime
d=sys.argv[1]
meta={"command":sys.argv[2],"status":sys.argv[3],
      "prompt":open(os.path.join(d,"prompt.txt")).read(),
      "created":datetime.datetime.now().isoformat(timespec="seconds"),
      "agents":[],"rounds":[]}
json.dump(meta,open(os.path.join(d,"meta.json"),"w"),indent=1)
PY
}
meta_add_agent() { # role engine slug secs rc extra_json
  python3 - "$RUN_DIR" "$@" <<'PY'
import json,sys,os
d=sys.argv[1]; m=json.load(open(os.path.join(d,"meta.json")))
extra=json.loads(sys.argv[7]) if len(sys.argv)>7 and sys.argv[7] else {}
m["agents"].append({"role":sys.argv[2],"engine":sys.argv[3],"slug":sys.argv[4],
                    "secs":int(sys.argv[5]),"rc":int(sys.argv[6]),**extra})
json.dump(m,open(os.path.join(d,"meta.json"),"w"),indent=1)
PY
}
meta_set() { # key value(json-encoded string ok)
  python3 - "$RUN_DIR" "$1" "$2" <<'PY'
import json,sys,os
d=sys.argv[1]; m=json.load(open(os.path.join(d,"meta.json")))
try: v=json.loads(sys.argv[3])
except Exception: v=sys.argv[3]
m[sys.argv[2]]=v
json.dump(m,open(os.path.join(d,"meta.json"),"w"),indent=1)
PY
}

# ── opinion ──────────────────────────────────────────────────────
if [ "$CMD" = opinion ] || [ "$CMD" = fuse ]; then
  meta_init running
  cat > "$RUN_DIR/p_architect.txt" <<EOF
You are the ARCHITECT in a two-model fusion harness. Answer the prompt below directly and completely, in markdown. Do NOT create or modify any files — answer only.

PROMPT:
$PROMPT
EOF
  cat > "$RUN_DIR/p_builder.txt" <<EOF
You are the BUILDER in a two-model fusion harness. Answer the prompt below directly and completely, in markdown. Do NOT create or modify any files — answer only.

PROMPT:
$PROMPT
EOF
  echo "── fanning out: ARCHITECT(claude) + BUILDER(codex) in parallel..."
  run_architect "$RUN_DIR/p_architect.txt" architect > "$RUN_DIR/.a_res" &
  A_PID=$!
  run_builder "$RUN_DIR/p_builder.txt" builder read-only > "$RUN_DIR/.b_res" &
  B_PID=$!
  wait "$A_PID"; wait "$B_PID"
  read -r A_SECS A_RC < <(tail -1 "$RUN_DIR/.a_res")
  read -r B_SECS B_RC < <(tail -1 "$RUN_DIR/.b_res")
  meta_add_agent ARCHITECT claude architect "$A_SECS" "$A_RC" "$(arch_stats architect)"
  meta_add_agent BUILDER codex builder "$B_SECS" "$B_RC" "$(build_stats builder)"
  echo "── ARCHITECT done in ${A_SECS}s (rc=$A_RC) · BUILDER done in ${B_SECS}s (rc=$B_RC)"
fi

if [ "$CMD" = opinion ]; then
  meta_set status done
  finish done
  exit 0
fi

# ── fuse: third agent merges ─────────────────────────────────────
if [ "$CMD" = fuse ]; then
  [ -n "$MERGE_INSTR" ] || MERGE_INSTR="Critically merge the two answers into the single best result. Attribute ideas inline as [ARCHITECT] or [BUILDER] (or [BOTH] on agreement). Prefer correctness over diplomacy: discard weak or wrong material and say so."
  cat > "$RUN_DIR/p_fusion.txt" <<EOF
You are the FUSION agent in a two-model harness. Two models independently answered the same prompt. $MERGE_INSTR

Structure your output EXACTLY as:
## Fused Result
## Consensus
## Divergence
## Discarded

ORIGINAL PROMPT:
$PROMPT

=== ARCHITECT ANSWER (claude) ===
$(cat "$RUN_DIR/architect.txt")

=== BUILDER ANSWER (codex) ===
$(cat "$RUN_DIR/builder.txt")
EOF
  echo "── FUSION agent (claude) merging..."
  read -r F_SECS F_RC < <(run_architect "$RUN_DIR/p_fusion.txt" fusion | tail -1)
  meta_add_agent FUSION claude fusion "$F_SECS" "$F_RC" "$(arch_stats fusion)"
  meta_set status done
  echo "── FUSION done in ${F_SECS}s (rc=$F_RC)"
  echo; echo "════ FUSED RESULT ════"; cat "$RUN_DIR/fusion.txt"
  finish done
  exit 0
fi

# ── autovalidate: gate-first build loop ──────────────────────────
if [ "$CMD" = autovalidate ]; then
  meta_init running
  WORKDIR="$(pwd)"
  cat > "$RUN_DIR/p_validator.txt" <<EOF
You are the VALIDATOR in a fusion harness. A separate builder agent will be given the task below. BEFORE any work happens, design the acceptance gate that proves the task is done.

Write an executable bash script to exactly this path: $RUN_DIR/gate.sh
(You have write access to that directory. If a write there is still denied, write the identical script to ./.fusion-gate.sh in the working directory instead.)
Requirements for gate.sh:
- Runs from this working directory: $WORKDIR
- Checks every concrete, verifiable property of a correct result (files exist, contents match, scripts run, outputs correct).
- Echo "PASS: <what passed>" per passing check and "FAIL: <specific, actionable feedback for the builder>" per failing check.
- Exit non-zero if ANY check fails; exit 0 only when all pass.
- Standard tools only (bash, grep, python3). Do NOT perform the task itself — only write the gate.

TASK THE BUILDER WILL RECEIVE:
$PROMPT
EOF
  echo "── VALIDATOR (claude) writing acceptance gate BEFORE any build..."
  read -r V_SECS V_RC < <(run_architect "$RUN_DIR/p_validator.txt" validator acceptEdits "$RUN_DIR" | tail -1)
  meta_add_agent VALIDATOR claude validator "$V_SECS" "$V_RC" "$(arch_stats validator)"
  # Fallback: nested-session sandboxes sometimes only allow cwd writes.
  [ -f "$RUN_DIR/gate.sh" ] || { [ -f "$WORKDIR/.fusion-gate.sh" ] && mv "$WORKDIR/.fusion-gate.sh" "$RUN_DIR/gate.sh"; }
  [ -f "$RUN_DIR/gate.sh" ] || { echo "validator produced no gate.sh — aborting" >&2; meta_set status no-gate; finish no-gate; exit 1; }
  cp "$RUN_DIR/gate.sh" "$RUN_DIR/gate.sh.orig"; chmod 555 "$RUN_DIR/gate.sh"
  echo "── gate written ($(grep -c "" "$RUN_DIR/gate.sh") lines). Initial run (expected to fail):"
  ( cd "$WORKDIR" && bash "$RUN_DIR/gate.sh" ) > "$RUN_DIR/gate_round_0.log" 2>&1
  grep -E "^(PASS|FAIL)" "$RUN_DIR/gate_round_0.log" | head -8 | sed 's/^/    /'

  STATUS=failed
  for round in $(seq 1 "$ROUNDS"); do
    FEEDBACK="$(grep -E "^FAIL" "$RUN_DIR/gate_round_$((round-1)).log" || true)"
    cat > "$RUN_DIR/p_builder_r$round.txt" <<EOF
You are the BUILDER in a fusion harness (round $round/$ROUNDS). Complete the task below in the current working directory.

An acceptance gate script exists at $RUN_DIR/gate.sh — READ it to understand exactly what is checked, but NEVER modify it. Your work is done only when the gate passes.

TASK:
$PROMPT

CURRENT GATE FAILURES TO FIX (verbatim):
${FEEDBACK:-(no gate run yet)}
EOF
    echo "── BUILDER (codex) round $round..."
    read -r B_SECS B_RC < <(run_builder "$RUN_DIR/p_builder_r$round.txt" "builder_r$round" workspace-write | tail -1)
    meta_add_agent "BUILDER-r$round" codex "builder_r$round" "$B_SECS" "$B_RC" "$(build_stats builder_r$round)"
    cmp -s "$RUN_DIR/gate.sh" "$RUN_DIR/gate.sh.orig" || { echo "── gate was tampered with — restoring"; chmod 755 "$RUN_DIR/gate.sh"; cp "$RUN_DIR/gate.sh.orig" "$RUN_DIR/gate.sh"; chmod 555 "$RUN_DIR/gate.sh"; }
    ( cd "$WORKDIR" && bash "$RUN_DIR/gate.sh" ) > "$RUN_DIR/gate_round_$round.log" 2>&1
    GRC=$?
    grep -E "^(PASS|FAIL)" "$RUN_DIR/gate_round_$round.log" | sed 's/^/    /'
    if [ "$GRC" -eq 0 ]; then STATUS=green; echo "── GATE GREEN after round $round ✅"; break; fi
    echo "── gate still failing after round $round"
  done
  meta_set status "$STATUS"
  meta_set gate_rounds "$round"
  finish "$STATUS"
  [ "$STATUS" = green ] || exit 1
fi
