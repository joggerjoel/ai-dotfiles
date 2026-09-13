"""
The supervisor-owned machine context pack (plan 4).

Parsed from the copy at ~/.herdr-master/machines/<profile>/MACHINE.md, never from the
agent-writable checkout: a worker that can set its own test_cmd can pass any gate (2.1).

Section 4 states that "every absence has a defined consequence rather than a silent
default", so absence is modelled three ways and never as None-and-hope. A field whose
absence breaks dispatch is required and its omission raises. A field with a stated
default gets that default. A field whose absence disables one feature records a
deferred consequence the caller must check before using that feature.
"""

import dataclasses
import re

TEST_TIMEOUT_MS = 600000
STALL_IDLE_SECONDS = 900

# A group header may carry a parenthetical before its colon, as section 4's
# "- **Agent kinds & exhaustion patterns** (10.2; unlisted kind -> escalate):" does.
KEY = re.compile(r"^\s*-\s+\*\*(?P<key>[^*]+)\*\*\s*(?:\([^)]*\))?\s*:\s*(?P<value>.*?)\s*$")
SUBKEY = re.compile(r"^\s+-\s+`(?P<key>[^`]+)`\s*:\s*(?P<value>.*?)\s*$")
BACKTICKED = re.compile(r"`([^`]*)`")
TRAILING_COMMENT = re.compile(r"\s+#.*$")
# /pattern/flags -> pattern. A bare rstrip("i") would eat a trailing literal "i".
DELIMITED = re.compile(r"^/(.*)/[a-z]*$")


class MachineConfigError(ValueError):
    """Carries every problem at once; a config fixed one error per run wastes a run per typo."""

    def __init__(self, problems):
        self.problems = problems
        super().__init__("; ".join(problems))


def _clean(value):
    """Resolve one value.

    Dispatch on the first character rather than searching for backticks anywhere, because
    a trailing comment may itself contain them: section 4's Profile line ends in
    "# must match a 7 registered profile, or `local`", and a naive backtick search
    returns "local" as the profile name. A backticked value also may contain '#', so
    comment-stripping cannot come first either.
    """
    value = value.strip()
    if value.startswith("`"):
        found = BACKTICKED.findall(value)
        return found[0] if found else value
    if value.startswith("["):
        return BACKTICKED.findall(value)
    return TRAILING_COMMENT.sub("", value).strip()


@dataclasses.dataclass(frozen=True)
class MachineConfig:
    machine_id: str
    profile: str
    working_directory: str
    base_branch: str
    worktree_root: str
    worker_pane: str
    verify_pane: str
    shell_pane: str
    test_cmd: str
    lint_cmd: str | None = None
    timezone: str | None = None
    test_timeout_ms: int = TEST_TIMEOUT_MS
    stall_idle_seconds: int = STALL_IDLE_SECONDS
    exhaustion_patterns: dict = dataclasses.field(default_factory=dict)
    allowed_registries: tuple = ()
    allowed_installers: tuple = ()

    def exhaustion_pattern(self, kind):
        """An unlisted kind escalates rather than defaulting to a pattern that may not match (4, 10.2)."""
        try:
            return self.exhaustion_patterns[kind]
        except KeyError:
            raise MachineConfigError(
                [f"agent kind {kind!r} has no exhaustion pattern; 4 escalates on an unlisted kind"]
            ) from None

    def require_timezone(self):
        """Absent -> rate-limit events escalate (4, 9.3). Checked here rather than at the sleep."""
        if not self.timezone:
            raise MachineConfigError(
                ["Timezone is absent; 9.3 rate-limit handling escalates rather than guessing a reset time"]
            )
        return self.timezone


def parse(text):
    flat, sub, current = {}, {}, None
    for line in text.splitlines():
        hit = SUBKEY.match(line)
        if hit:
            sub.setdefault(current or "", {})[hit.group("key")] = _clean(hit.group("value"))
            continue
        hit = KEY.match(line)
        if not hit:
            continue
        key, value = hit.group("key").strip(), hit.group("value")
        current = key
        if value:
            flat[key] = _clean(value)

    merged = {}
    for group in sub.values():
        merged.update(group)

    problems = []

    def required(key, source, consequence):
        value = source.get(key)
        if not value:
            problems.append(f"{key} is absent; {consequence}")
        return value

    def integer(key, default):
        raw = merged.get(key)
        if raw is None:
            return default
        try:
            return int(str(raw))
        except ValueError:
            problems.append(f"{key} is {raw!r}, expected an integer")
            return default

    machine_id = required("Machine ID", flat, "the supervisor cannot address this machine")
    profile = required("Profile", flat, "7 cannot resolve a transport for this machine")
    workdir = required("Working Directory", flat, "2.4 cannot locate the repo")
    base = required("Base Branch", flat, "2.4 TODO-lane dispatch escalates")
    root = required("Worktree Root", flat, "2.4 cannot place a worktree")
    worker = required("worker_pane", merged, "3 has nowhere to dispatch")
    verify = required("verify_pane", merged, "6 has nowhere to verify; a unit can never be marked done")
    shell = required("shell_pane", merged, "2.3 has nowhere to run git and file work")
    test_cmd = required("test_cmd", merged, "6 cannot verify; the unit escalates rather than passing")

    timeout = integer("test_timeout_ms", TEST_TIMEOUT_MS)
    stall = integer("stall_idle_seconds", STALL_IDLE_SECONDS)

    # Matched on a prefix rather than the full header, which carries a parenthetical
    # and is prose the plan may reword.
    patterns = {}
    for header, group in sub.items():
        if header.startswith("Agent kinds"):
            patterns.update(group)
    for kind, pattern in patterns.items():
        try:
            re.compile(DELIMITED.sub(r"\1", pattern))
        except re.error as exc:
            problems.append(f"exhaustion pattern for {kind!r} does not compile: {exc}")

    if problems:
        raise MachineConfigError(problems)

    def listed(key):
        value = merged.get(key, ())
        return tuple(value) if isinstance(value, list) else ((value,) if value else ())

    return MachineConfig(
        machine_id=machine_id,
        profile=profile,
        working_directory=workdir,
        base_branch=base,
        worktree_root=root,
        worker_pane=worker,
        verify_pane=verify,
        shell_pane=shell,
        test_cmd=test_cmd,
        lint_cmd=merged.get("lint_cmd"),
        timezone=flat.get("Timezone"),
        test_timeout_ms=timeout,
        stall_idle_seconds=stall,
        exhaustion_patterns=patterns,
        allowed_registries=listed("allowed_registries"),
        allowed_installers=listed("allowed_installers"),
    )


def load(path):
    with open(path, encoding="utf-8") as handle:
        return parse(handle.read())
