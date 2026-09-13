"""Readiness CLI tests with synthetic modules; no live agents or network."""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("herdr-temporal-check.py")
OWNER = "a340a839-df09-480d-bd39-fa89b42bba4f"


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.root = self.directory / "state"
        self.prefix = self.directory / "installation"
        self.dotfiles = self.directory / "dotfiles"
        validator = self.dotfiles / "skills/amnesiac-workers/scripts/validate_state.py"
        validator.parent.mkdir(parents=True)
        validator.write_text("")
        binaries = self.directory / "bin"
        binaries.mkdir()
        for name in ("git", "herdr", "codex"):
            path = binaries / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(binaries), HERDR_ENV="")

    def run_check(self, *options):
        return subprocess.run([sys.executable, str(SCRIPT), "--root", str(self.root),
                               "--prefix", str(self.prefix), "--dotfiles", str(self.dotfiles),
                               *options], env=self.environment, text=True, capture_output=True, timeout=15)

    def install_fixture(self):
        release = self.prefix / "releases/fixture"
        modules = release / "herdr_master"
        modules.mkdir(parents=True)
        (modules / "temporal_cli.py").write_text("")
        (modules / "lifecycle.py").write_text(
            "from pathlib import Path\n"
            "class Config:\n"
            "    working_directory = '.'\n"
            "    base_branch = 'main'\n"
            "    worker_pane, verify_pane, shell_pane = 'worker', 'verify', 'shell'\n"
            "    def exhaustion_pattern(self, kind): return 'exhausted'\n"
            "class Profile:\n"
            "    def __init__(self, root, profile): self.path = root / 'machines' / profile / 'MACHINE.md'\n"
            "    def load_config(self):\n"
            "        self.path.read_text()\n"
            "        return Config(), None\n")
        (modules / "taskqueue.py").write_text(
            "class Queue:\n"
            "    def next_dispatchable(self): return 'task'\n"
            "def load(path):\n"
            "    path.read_text()\n"
            "    return Queue()\n")
        python = release / ".venv/bin/python"
        python.parent.mkdir(parents=True)
        python.write_text("#!" + sys.executable + "\nfrom pathlib import Path\n"
                          "Path(" + repr(str(self.directory / "probe-called")) + ").touch()\n")
        python.chmod(0o755)
        (self.prefix / "current").symlink_to(release)

    def profile_fixture(self):
        machine = self.root / "machines/local"
        machine.mkdir(parents=True)
        (machine / "MACHINE.md").write_text("approved fixture")
        (machine / "TODO.md").write_text("- [ ] fixture task")
        (self.root / "temporal-owned").write_text(OWNER)
        with sqlite3.connect(self.root / "state.db") as database:
            database.execute("CREATE TABLE pane_names (profile TEXT, name TEXT, pane_id TEXT)")
            database.executemany("INSERT INTO pane_names VALUES ('local', ?, ?)",
                                 [(name, str(index)) for index, name in enumerate(("worker", "verify", "shell"), 1)])

    def snapshot(self):
        return {str(path): (path.stat().st_mtime_ns, hashlib.sha256(path.read_bytes()).hexdigest())
                for path in self.directory.rglob("*") if path.is_file()}

    def test_missing_installation_reports_needs_setup_without_creating_state(self):
        before = self.snapshot()
        result = self.run_check("--offline")
        self.assertEqual(result.returncode, 2, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["status"], "needs-setup")
        self.assertFalse(report["checks"][0]["passed"])
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.root.exists())
        self.assertFalse(self.prefix.exists())

    def test_missing_profile_does_not_create_database_or_probe_offline(self):
        self.install_fixture()
        before = self.snapshot()
        result = self.run_check("--offline")
        self.assertEqual(result.returncode, 2, result.stderr)
        checks = {entry["check"]: entry for entry in json.loads(result.stdout)["checks"]}
        self.assertFalse(checks["approved-profile"]["passed"])
        self.assertFalse((self.root / "state.db").exists())
        self.assertFalse((self.directory / "probe-called").exists())
        self.assertEqual(self.snapshot(), before)

    def test_identifiers_reject_paths_and_shell_input(self):
        for option, value in (("--profile", "../other"), ("--kind", "codex;echo bad"),
                              ("--profile", ""), ("--kind", "x" * 65)):
            with self.subTest(option=option, value=value):
                result = self.run_check(option, value, "--offline")
                self.assertEqual(result.returncode, 2)
                self.assertIn("profile", result.stderr)
                self.assertFalse(self.root.exists())

    def test_valid_offline_configuration_is_read_only_and_does_not_probe(self):
        self.install_fixture()
        self.profile_fixture()
        before = self.snapshot()
        result = self.run_check("--offline")
        self.assertEqual(result.returncode, 2, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["status"], "needs-setup")
        self.assertTrue(all(entry["passed"] for entry in report["checks"] if entry["check"] != "temporal"))
        self.assertEqual(report["task_queue"], "herdr-" + OWNER + "-local-codex")
        self.assertFalse(report["inside_herdr"])
        self.assertFalse((self.directory / "probe-called").exists())
        self.assertEqual(self.snapshot(), before)

    def test_uncertain_receipt_blocks_readiness_without_mutation(self):
        self.install_fixture()
        self.profile_fixture()
        with sqlite3.connect(self.root / "temporal-receipts.sqlite3") as database:
            database.execute("CREATE TABLE operations (state TEXT)")
            database.execute("INSERT INTO operations VALUES ('uncertain')")
        before = self.snapshot()
        result = self.run_check("--offline")
        self.assertEqual(result.returncode, 2, result.stderr)
        report = json.loads(result.stdout)
        checks = {entry["check"]: entry for entry in report["checks"]}
        self.assertFalse(checks["receipts"]["passed"])
        self.assertIn("1 unresolved", checks["receipts"]["detail"])
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main()
