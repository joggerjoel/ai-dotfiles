#!/bin/bash
# Deliberately fails, on purpose — this is a test fixture, not a real smoke
# script for context7. tests/preflight/run.sh wires this onto the `healthy`
# fixture solely to isolate the "a smoke failure causes exit 1" ordering
# assertions (both human and --json --smoke), since `healthy` is otherwise
# the suite's all-green negative control and has no other tier-3 script to
# exercise that path.
#
# It only affects `--smoke` runs: tier 2 (the default, no-flag run) never
# invokes tests/smoke/ scripts, so `healthy` remains a fully valid negative
# control (exit 0, zero findings) for every non-smoke assertion in the suite.
echo "smoke: context7 tool call failed"
exit 1
