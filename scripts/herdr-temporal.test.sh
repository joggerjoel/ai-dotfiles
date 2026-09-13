#!/usr/bin/env bash
# Picked up by run-all-tests.sh and CI. Fixtures never invoke real Herdr or uv.
set -euo pipefail
temporal_test_dir=$(cd "$(dirname "$0")" && pwd)
python3 - "$temporal_test_dir" <<'PY'
import sys
import unittest
suite = unittest.defaultTestLoader.discover(sys.argv[1], pattern="test_herdr_temporal*.py")
result = unittest.TextTestRunner(verbosity=1).run(suite)
failed = len(result.failures) + len(result.errors)
print(f"{result.testsRun - failed - len(result.skipped)} passed, {failed} failed")
raise SystemExit(0 if result.wasSuccessful() else 1)
PY
