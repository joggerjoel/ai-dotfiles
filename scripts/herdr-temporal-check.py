#!/usr/bin/env python3
"""Read-only configuration and connectivity checks; never launch or enroll agents."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
from urllib.parse import quote
import uuid


def inspect(args):
    checks = []

    def record(name, passed, detail):
        checks.append({"check": name, "passed": bool(passed), "detail": detail})

    root = args.root.expanduser().resolve()
    release = (args.prefix.expanduser() / "current").resolve()
    python = release / ".venv/bin/python"
    record("release", python.is_file() and (release / "herdr_master/temporal_cli.py").is_file(), str(release))
    for binary in ("herdr", args.kind, "git"):
        found = shutil.which(binary)
        record("binary:" + binary, found is not None, found or "not installed or not on PATH")
    dotfiles = args.dotfiles.expanduser().resolve()
    validator = dotfiles / "skills/amnesiac-workers/scripts/validate_state.py"
    record("packet-validator", validator.is_file(), str(validator))
    cfg = None
    if checks[0]["passed"]:
        sys.dont_write_bytecode = True
        sys.path.insert(0, str(release / "herdr_master"))
        try:
            import lifecycle
            import taskqueue
            cfg, _ = lifecycle.Profile(root, args.profile).load_config()
            cfg.exhaustion_pattern(args.kind)
            record("approved-profile", True, "trusted machine configuration matches its digest")
            repo = Path(cfg.working_directory).expanduser()
            done = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", cfg.base_branch + "^{commit}"],
                                  capture_output=True, timeout=10, check=False)
            record("repository", done.returncode == 0, "repository and configured base ref" )
            queue = taskqueue.load(root / "machines" / args.profile / "TODO.md")
            record("approved-queue", queue.next_dispatchable() is not None, "requires a dispatchable task")
        except Exception as exc:
            record("approved-profile", False, type(exc).__name__ + ": profile, repository, or queue check failed; inspect locally")
    database = root / "state.db"
    if cfg is not None and database.is_file():
        try:
            with sqlite3.connect("file:" + quote(str(database)) + "?mode=ro", uri=True) as db:
                names = dict(db.execute("SELECT name, pane_id FROM pane_names WHERE profile=?", (args.profile,)))
            expected = (cfg.worker_pane, cfg.verify_pane, cfg.shell_pane)
            record("pane-bindings", all(names.get(name) for name in expected), "recorded bindings only; live panes not inspected")
        except sqlite3.Error:
            record("pane-bindings", False, "cannot read recorded bindings")
    else:
        record("pane-bindings", False, "prepare and bind a machine profile inside Herdr")
    marker = root / "temporal-owned"
    owner = None
    if marker.is_file():
        try:
            owner = str(uuid.UUID(marker.read_text().strip()))
            record("enrollment", True, "existing local enrollment")
        except (ValueError, OSError):
            record("enrollment", False, "invalid enrollment; do not overwrite it")
    else:
        record("enrollment", False, "not enrolled; start the worker inside Herdr after setup")
    receipts = root / "temporal-receipts.sqlite3"
    if receipts.is_file():
        try:
            with sqlite3.connect("file:" + quote(str(receipts)) + "?mode=ro", uri=True) as db:
                unresolved = db.execute("SELECT COUNT(*) FROM operations WHERE state != 'completed'").fetchone()[0]
            record("receipts", unresolved == 0, f"{unresolved} unresolved operations; never delete receipts to retry")
        except sqlite3.Error:
            record("receipts", False, "cannot read receipts; reconcile locally")
    else:
        record("receipts", True, "no receipt journal yet")
    if args.offline:
        record("temporal", False, "not checked (--offline)")
    elif python.is_file():
        probe = """import asyncio, sys
from temporalio.client import Client
from temporalio.api.workflowservice.v1 import DescribeNamespaceRequest
async def check():
    client = await Client.connect(sys.argv[1], namespace=sys.argv[2])
    await client.workflow_service.describe_namespace(DescribeNamespaceRequest(namespace=sys.argv[2]))
asyncio.run(asyncio.wait_for(check(), timeout=8))
"""
        try:
            result = subprocess.run([str(python), "-B", "-c", probe, args.address, args.namespace],
                                    capture_output=True, timeout=12, check=False)
            record("temporal", result.returncode == 0,
                   "API and namespace reachable; no workflows submitted" if result.returncode == 0
                   else "API/namespace probe failed; check tunnel, namespace, and access")
        except (OSError, subprocess.TimeoutExpired):
            record("temporal", False, "connection probe failed or timed out")
    else:
        record("temporal", False, "install worker runtime first")
    passed = all(check["passed"] for check in checks)
    return {"status": "configuration-ready" if passed else "needs-setup",
            "checks": checks, "task_queue": f"herdr-{owner}-{args.profile}-{args.kind}" if owner else None,
            "inside_herdr": os.environ.get("HERDR_ENV") == "1",
            "authentication": "not-checked; verify subscription login locally",
            "live_panes": "not-checked; inspect only inside the owning Herdr session",
            "dispatch_ready": False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=Path.home() / ".local/share/herdr-temporal")
    parser.add_argument("--root", type=Path, default=Path.home() / ".herdr-temporal/local")
    parser.add_argument("--profile", default="local")
    parser.add_argument("--kind", default="codex")
    parser.add_argument("--address", default="localhost:7233")
    parser.add_argument("--namespace", default="herdr")
    parser.add_argument("--dotfiles", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args(argv)
    for value in (args.profile, args.kind):
        if not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", value):
            parser.error("profile and kind must be simple identifiers")
    report = inspect(args)
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "configuration-ready" else 2


if __name__ == "__main__":
    raise SystemExit(main())
