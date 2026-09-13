"""Exercise the public release CLI with temporary sources and a fake uv."""
import hashlib
import fcntl
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("herdr-temporal-release.py")


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "herdr_master").mkdir()
        for name in ("herdr-temporal", "herdr_unblocker.py", "requirements-temporal.txt", "MACHINE.template.md"):
            (self.source / name).write_text("template\n")
        (self.source / "herdr_master/temporal_cli.py").write_text("print('worker help')\n")
        (self.source / "herdr_master/cli.py").write_text("print('master help')\n")
        self.prefix = self.root / "installed"
        self.artifact = self.root / "worker.tar.gz"
        binaries = self.root / "bin"
        binaries.mkdir()
        fake = binaries / "uv"
        fake.write_text("#!" + sys.executable + "\n" +
                        "import os, pathlib, sys\n"
                        "with open(os.environ['UV_LOG'], 'a') as log: log.write(sys.argv[1] + '\\n')\n"
                        "if os.environ.get('UV_FAIL'): sys.exit(1)\n"
                        "if sys.argv[1] == 'venv':\n"
                        "    target = pathlib.Path(sys.argv[-1]) / 'bin'\n"
                        "    target.mkdir(parents=True)\n"
                        "    (target / 'python').symlink_to(sys.executable)\n")
        fake.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'],
                                UV_LOG=str(self.root / "uv.log"))

    def cli(self, *args, success=True):
        result = subprocess.run([sys.executable, str(SCRIPT), *map(str, args)],
                                env=self.environment, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)
        return result

    def build(self):
        return self.cli("bundle", "--source", self.source, "--output", self.artifact)

    def install(self, sha, success=True):
        return self.cli("install", "--artifact", self.artifact, "--sha256", sha,
                        "--prefix", self.prefix, "--dotfiles", self.source, success=success)

    def test_bundle_deterministic_and_excludes_state_tests_secrets(self):
        for name in (".env", "MACHINE.md", "TODO.md"):
            (self.source / name).write_text("private")
        for name in ("test_private.py", "smoke_live.py"):
            (self.source / "herdr_master" / name).write_text("private")
        first = self.build()
        os.utime(self.source / "herdr-temporal", (17, 18))
        self.assertEqual(self.build(), first)
        with tarfile.open(self.artifact) as archive:
            self.assertEqual(sorted(archive.getnames()), ["MACHINE.template.md", "herdr-temporal",
                             "herdr_master/cli.py", "herdr_master/temporal_cli.py", "herdr_unblocker.py", "requirements-temporal.txt"])

    def test_source_symlink_rejected(self):
        (self.source / "herdr_master/helper.py").symlink_to(self.source / "MACHINE.template.md")
        self.cli("bundle", "--source", self.source, "--output", self.artifact, success=False)
        self.assertFalse(self.artifact.exists())

    def test_checksum_failure_has_no_install_side_effects(self):
        self.build()
        result = self.install("0" * 64, success=False)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertFalse(self.prefix.exists())

    def test_traversal_links_and_unexpected_members_rejected(self):
        for name, kind in [("../escape.py", tarfile.REGTYPE), ("/escape.py", tarfile.REGTYPE),
                           ("herdr_master/helper.py", tarfile.SYMTYPE),
                           ("herdr_master/helper.py", tarfile.LNKTYPE),
                           (".env", tarfile.REGTYPE), ("herdr_master//helper.py", tarfile.REGTYPE)]:
            with self.subTest(name=name, kind=kind):
                with tarfile.open(self.artifact, "w:gz") as archive:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.linkname = "../../escape"
                    archive.addfile(member, io.BytesIO(b""))
                sha = hashlib.sha256(self.artifact.read_bytes()).hexdigest()
                self.install(sha, success=False)
                self.assertFalse(self.prefix.exists())

    def test_install_and_repeat_preserve_existing_files(self):
        sha = self.build()["sha256"]
        result = self.install(sha)
        release = Path(result["release"])
        wrapper = Path(result["executable"])
        self.assertEqual((self.prefix / "current").resolve(), release)
        before = {str(path): path.lstat().st_mtime_ns for path in self.prefix.rglob("*")}
        self.assertTrue(result["changed"])
        self.assertEqual(self.install(sha), dict(result, changed=False))
        self.assertEqual(before, {str(path): path.lstat().st_mtime_ns for path in self.prefix.rglob("*")})
        self.assertEqual((self.root / "uv.log").read_text(), "venv\npip\n")
        run = subprocess.run([str(wrapper), "--help"], text=True, capture_output=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout, "worker help\n")
        master = subprocess.run([str(self.prefix / "bin/herdr-master"), "--help"], text=True, capture_output=True)
        self.assertEqual(master.returncode, 0, master.stderr)
        self.assertEqual(master.stdout, "master help\n")

    def test_failed_install_preserves_current_and_retry_recovers(self):
        first = self.install(self.build()["sha256"])
        (self.source / "herdr_master/temporal_cli.py").write_text("print('new worker help')\n")
        sha = self.build()["sha256"]
        self.environment["UV_FAIL"] = "1"
        self.install(sha, success=False)
        self.assertEqual((self.prefix / "current").resolve(), Path(first["release"]))
        self.environment.pop("UV_FAIL")
        second = self.install(sha)
        self.assertEqual((self.prefix / "current").resolve(), Path(second["release"]))
        self.assertEqual(len(list((self.prefix / "releases").glob(sha + ".incomplete-*"))), 1)
        self.assertTrue(Path(first["release"]).is_dir())

    def test_failed_help_does_not_activate_release(self):
        (self.source / "herdr_master/temporal_cli.py").write_text("raise SystemExit(3)\n")
        self.install(self.build()["sha256"], success=False)
        self.assertFalse((self.prefix / "current").exists())

    def test_busy_install_lock_fails_without_building_release(self):
        sha = self.build()["sha256"]
        self.prefix.mkdir()
        with (self.prefix / ".install.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.install(sha, success=False)
        self.assertFalse((self.prefix / "releases").exists())

    def test_duplicate_archive_member_rejected(self):
        with tarfile.open(self.artifact, "w:gz") as archive:
            for _ in range(2):
                archive.addfile(tarfile.TarInfo("herdr-temporal"), io.BytesIO(b""))
        sha = hashlib.sha256(self.artifact.read_bytes()).hexdigest()
        self.install(sha, success=False)
        self.assertFalse(self.prefix.exists())

    def test_real_source_bundle_can_import_lifecycle_without_source_checkout(self):
        source = SCRIPT.parents[2] / "herdr-orchestrator"
        if not (source / "herdr_master/lifecycle.py").is_file():
            self.skipTest("sibling herdr-orchestrator checkout unavailable")
        self.cli("bundle", "--source", source, "--output", self.artifact)
        extracted = self.root / "extracted"
        extracted.mkdir()
        with tarfile.open(self.artifact) as archive:
            self.assertIn("herdr_unblocker.py", archive.getnames())
            for member in archive:
                self.assertTrue(member.isfile())
                target = extracted / member.name
                target.parent.mkdir(exist_ok=True)
                target.write_bytes(archive.extractfile(member).read())
        result = subprocess.run([sys.executable, "-B", "-c",
                                 "import sys; sys.path.insert(0, sys.argv[1]); import lifecycle; print(lifecycle.Result.VERIFIED.value)",
                                 str(extracted / "herdr_master")], cwd=extracted,
                                env=dict(self.environment, AI_DOTFILES_ROOT=str(SCRIPT.parents[1])),
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "verified\n")


if __name__ == "__main__":
    unittest.main()
