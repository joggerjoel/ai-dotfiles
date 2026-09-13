#!/bin/bash
# One amnesiac attempt: fresh pane, fresh agent, packet from repo + last failure, destroy.
#
# PROTOTYPE. This drove the full 3 lifecycle end to end on 2026-09-12, on both a
# passing task and an unsatisfiable one, and every §2.3 finding recorded in the plan
# came out of running it. It is the seed for Phase 3's dispatcher (see
# master-control-herdr-todo.md), not production code: no state.db, no queue, no
# escalation, no leases, no secret scan, and the pane it splits from is hardcoded.
#
# Usage: attempt_prototype.sh <attempt-n> <tree> <verify-pane>
set -u

N="$1"; TREE="$2"; VERIFY="$3"
NONCE="a${N}$(openssl rand -hex 3)"
STATE="$(dirname "$TREE")/$(basename "$TREE")-state.json"

say() { printf '[attempt %s] %s\n' "$N" "$*"; }

LAST_FAIL="none, this is the first attempt"
if [ -f "$STATE" ]; then
  LAST_FAIL=$(python3 - "$STATE" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])).get("verification")
print("none" if not v else "%s exited %s\n%s" % (v["command"], v["exit_code"], v["excerpt"]))
PY
)
fi

WORKER=$(herdr pane split w9:pA --direction down --no-focus --cwd "$TREE" | jq -r '.result.pane.pane_id')
say "pane $WORKER nonce $NONCE"

herdr agent start "mc-a$N" --kind claude --pane "$WORKER" --timeout 25000 >/dev/null 2>&1
for _ in $(seq 1 15); do
  st=$(herdr agent get "mc-a$N" 2>/dev/null | jq -r '.result.agent.agent_status // "none"')
  lp=$(herdr agent get "mc-a$N" 2>/dev/null | jq -r '.result.agent.launch_pending // "null"')
  [ "$st" = "blocked" ] && [ "$lp" = "true" ] && { herdr agent send-keys "mc-a$N" down enter >/dev/null; say "cleared trust prompt"; break; }
  [ "$st" = "idle" ] && { say "ready without a startup block"; break; }
  sleep 2
done
sleep 3

PACKET="GOAL: make ./verify.sh pass. You are in $TREE. Edit slugify.py only; do NOT edit test_slugify.py.
SPEC.md in the repo states the requirements. Run ./verify.sh yourself to check.

LAST VERIFIER FAILURE:
$LAST_FAIL

If the goal is UNREACHABLE (the spec contradicts itself, a test cannot be satisfied alongside another,
or something outside this repo is missing), do NOT keep trying. Write .herdr/blockers.json with:
{\"schema\":1,\"blockers\":[{\"need\":\"<what is missing, as an observation>\",\"blocks\":\"<todo item>\",
\"observed_via\":\"<command you ran>\",\"exit_code\":<n>,\"excerpt\":\"<literal output>\",\"observed_at\":\"<ISO8601>\"}]}
Record only what a command printed, never what you think it means.

When completely finished, print the token MC-DONE followed by a space and $NONCE, and nothing after it."

herdr agent prompt "mc-a$N" "$PACKET" --wait --until working --timeout 15000 >/dev/null 2>&1
say "dispatched"

for _ in $(seq 1 60); do
  st=$(herdr agent get "mc-a$N" 2>/dev/null | jq -r '.result.agent.agent_status // "none"')
  case "$st" in idle|done) break ;; blocked) say "BLOCKED mid-attempt"; break ;; esac
  sleep 5
done
say "agent settled at: $st"

herdr pane run "$VERIFY" "cd '$TREE' && { ./verify.sh ; } ; printf 'MC-EXIT $NONCE %d\\n' \"\$?\"" >/dev/null
LINE=$(herdr pane wait-output "$VERIFY" --regex "MC-EXIT $NONCE [0-9]+" --source recent-unwrapped --timeout 90000 | jq -r '.result.matched_line')
CODE=$(printf '%s' "$LINE" | awk '{print $3}')
say "verifier: $LINE"

EXCERPT=$(herdr pane read "$VERIFY" --source recent-unwrapped --lines 40 | grep -E "^(FAIL|ERROR|AssertionError|Ran |FAILED|OK)" | tail -5)
python3 - "$STATE" "$N" "$CODE" "$EXCERPT" <<'PY'
import json, sys
path, n, code, excerpt = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
json.dump({"schema": 1, "unit_id": "slugify-hard", "attempt": n, "retry_budget": 3 - n,
           "verification": {"command": "./verify.sh", "exit_code": code, "excerpt": excerpt}},
          open(path, "w"), indent=1)
PY

git -C "$TREE" -c core.hooksPath=/dev/null add -A >/dev/null
git -C "$TREE" -c core.hooksPath=/dev/null commit -qm "attempt $N (verifier exit $CODE)" >/dev/null 2>&1 && say "committed $(git -C "$TREE" rev-parse --short HEAD)"

herdr pane close "$WORKER" >/dev/null
say "worker destroyed"
exit "$CODE"
