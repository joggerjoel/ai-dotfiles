#!/usr/bin/env python3
"""Build deterministic, state-free worker bundles and install immutable releases."""
import argparse
import contextlib
import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys
import tarfile
import tempfile
import uuid

ROOT_FILES = {"herdr-temporal", "herdr_unblocker.py", "requirements-temporal.txt", "MACHINE.template.md"}
REQUIRED_FILES = ROOT_FILES | {"herdr_master/temporal_cli.py", "herdr_master/cli.py"}
MAX_BYTES = 32 * 1024 * 1024


def allowed(name):
    parts = PurePosixPath(name).parts
    return name in ROOT_FILES or (
        len(parts) == 2 and parts[0] == "herdr_master"
        and re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*\.py", parts[1])
        and not parts[1].startswith("test") and "smoke" not in parts[1]
    )


def digest(data):
    return hashlib.sha256(data).hexdigest()


def atomic_write(path, data, mode=0o600):
    fd, temporary = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    with os.fdopen(fd, "wb") as output:
        os.fchmod(output.fileno(), mode)
        output.write(data)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)


def bundle(source, output):
    source = source.resolve(strict=True)
    module_dir = source / "herdr_master"
    if module_dir.is_symlink() or not module_dir.is_dir():
        raise ValueError("herdr_master must be a real directory")
    names = sorted(ROOT_FILES | {
        "herdr_master/" + entry.name for entry in module_dir.iterdir()
        if allowed("herdr_master/" + entry.name)
    })
    if not REQUIRED_FILES <= set(names):
        raise ValueError("source lacks required CLI modules")
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", filename="", mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w") as archive:
            total = 0
            for name in names:
                path = source / name
                if path.is_symlink() or not path.is_file():
                    raise ValueError("bundle files must be regular files: " + name)
                data = path.read_bytes()
                total += len(data)
                if total > MAX_BYTES:
                    raise ValueError("bundle exceeds size limit")
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o755 if name == "herdr-temporal" else 0o644
                archive.addfile(info, io.BytesIO(data))
    data = buffer.getvalue()
    output = output.absolute()
    atomic_write(output, data)
    return {"artifact": str(output), "sha256": digest(data)}


def validated_members(data):
    members = {}
    total = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive:
            if not member.isfile() or not allowed(member.name) or member.name in members:
                raise ValueError("unexpected archive member: " + member.name)
            # Reject alternative spellings such as ./, // and parent traversal.
            if str(PurePosixPath(member.name)) != member.name:
                raise ValueError("noncanonical archive member")
            total += member.size
            if member.size < 0 or total > MAX_BYTES:
                raise ValueError("archive exceeds size limit")
            with archive.extractfile(member) as stream:
                members[member.name] = stream.read()
    if not REQUIRED_FILES <= members.keys():
        raise ValueError("archive lacks required worker files")
    return members


@contextlib.contextmanager
def install_lock(prefix):
    prefix.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (prefix / ".install.lock").open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def install(artifact, sha256, prefix, dotfiles):
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise ValueError("sha256 must be 64 lowercase hex characters")
    data = artifact.read_bytes()
    if digest(data) != sha256:
        raise ValueError("artifact checksum mismatch")
    members = validated_members(data)
    dotfiles = dotfiles.resolve(strict=True)
    if not dotfiles.is_dir():
        raise ValueError("dotfiles must be an existing directory")
    prefix = prefix.resolve()
    changed = False
    with install_lock(prefix):
        releases = prefix / "releases"
        releases.mkdir(exist_ok=True)
        release = releases / sha256
        marker = release / ".installed.json"
        expected = {"sha256": sha256, "dotfiles": str(dotfiles)}
        if marker.is_file():
            if json.loads(marker.read_text()) != expected:
                raise ValueError("release was installed with different dotfiles path")
        else:
            changed = True
            if release.exists() or release.is_symlink():
                release.rename(releases / (sha256 + ".incomplete-" + uuid.uuid4().hex))
            release.mkdir(mode=0o700)
            for name, contents in members.items():
                path = release / name
                path.parent.mkdir(exist_ok=True)
                path.write_bytes(contents)
                path.chmod(0o755 if name == "herdr-temporal" else 0o644)
            subprocess.run(["uv", "venv", "--python", "3.11", str(release / ".venv")],
                           check=True, timeout=120, stdout=sys.stderr)
            python = release / ".venv/bin/python"
            subprocess.run(["uv", "pip", "install", "--python", str(python), "-r",
                            str(release / "requirements-temporal.txt")],
                           check=True, timeout=120, stdout=sys.stderr)
            environment = dict(os.environ, AI_DOTFILES_ROOT=str(dotfiles), PYTHONDONTWRITEBYTECODE="1")
            subprocess.run([str(python), str(release / "herdr_master/temporal_cli.py"), "--help"],
                           check=True, timeout=120, env=environment, stdout=subprocess.PIPE)
            atomic_write(marker, (json.dumps(expected, sort_keys=True) + "\n").encode())
        for command, module in (("herdr-temporal", "temporal_cli.py"), ("herdr-master", "cli.py")):
            executable = prefix / "bin" / command
            wrapper = ("#!/bin/sh\nset -eu\n"
                       "release=$(CDPATH= cd -P -- " + shlex.quote(str(prefix / "current")) + " && pwd)\n"
                       "export AI_DOTFILES_ROOT=" + shlex.quote(str(dotfiles)) + "\n"
                       'exec "$release/.venv/bin/python" "$release/herdr_master/' + module + '" "$@"\n').encode()
            executable.parent.mkdir(exist_ok=True)
            if not executable.is_file() or executable.read_bytes() != wrapper:
                atomic_write(executable, wrapper, 0o755)
                changed = True
        current = prefix / "current"
        if not current.is_symlink() or current.resolve() != release.resolve():
            temporary = prefix / (".current-" + uuid.uuid4().hex)
            temporary.symlink_to(release)
            os.replace(temporary, current)
            changed = True
    return {"release": str(release), "sha256": sha256,
            "executable": str(prefix / "bin/herdr-temporal"), "changed": changed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("bundle")
    build.add_argument("--source", type=Path, required=True)
    build.add_argument("--output", type=Path, required=True)
    deploy = commands.add_parser("install")
    deploy.add_argument("--artifact", type=Path, required=True)
    deploy.add_argument("--sha256", required=True)
    deploy.add_argument("--prefix", type=Path, required=True)
    deploy.add_argument("--dotfiles", type=Path, required=True)
    args = vars(parser.parse_args())
    command = args.pop("command")
    try:
        print(json.dumps(bundle(**args) if command == "bundle" else install(**args), sort_keys=True))
    except (OSError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(2, str(error) + "\n")


if __name__ == "__main__":
    main()
