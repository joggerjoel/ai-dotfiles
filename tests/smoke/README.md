# Smoke tests

Optional per-asset scripts. `just audit` runs each one for an asset that
passed the tier-2 handshake. Exit 0 means pass; any other code means fail.

Naming: `mcp-<server>.sh`, `cli-<command>.sh`, `skill-<name>.sh`.

An asset with no file here is reported UNTESTED, never PASS. Coverage is a
number you can improve, not a silent gap.

Each script runs in a subshell under `timeout 60`, so a hung test becomes one
failure rather than a hung audit.
