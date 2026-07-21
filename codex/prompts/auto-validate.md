Run the two-model fusion harness in AUTO-VALIDATE mode on this task: $ARGUMENTS

Execute exactly, from the directory where the work should land:
bash "$HOME/.claude/skills/fusion/scripts/fusion.sh" autovalidate '<the task above, single-quoted safely>'

Flow (built into the harness — do not replicate it yourself): a VALIDATOR agent
(claude) writes an executable acceptance gate BEFORE any work; a BUILDER agent (codex,
workspace-write sandbox) builds; the gate runs; FAIL lines feed back verbatim; it loops
until green or 3 rounds (add --rounds N to change). Exit code 0 means the gate is green.

Then: report the gate verdict (green/failed + round count), list the PASS/FAIL lines
from the final gate run, and point at <run-dir>/report.html for the gate script and
per-round breakdown. If the gate ended red, relay the outstanding FAIL lines as the
next actions.
