"""
Typed client for the herdr CLI surfaces verified in plan 2.3 against herdr 0.9.0.

Only commands that were actually probed appear here. Where the plan assumed an
invocation that does not exist, this module exposes the real one and the docstring
names what was assumed, so a reader comparing the two documents is not misled.

Three measured behaviours shape the whole interface:

- `pane run` is fire-and-forget. It prints nothing and exits 0 whatever the command
  did, so `run_checked` is the only way to obtain an exit code.
- Most commands return JSON on stdout; `pane read`, `agent read`, and `agent wait`
  return plain text. `_json` and `_text` are separate for that reason.
- `agent prompt` refuses a blocked agent outright, so unblocking goes through
  send_keys and send_text and never through prompt.
"""

import dataclasses
import json
import re
import secrets
import shlex
import subprocess

SENTINEL = "MC-EXIT"       # status line from a wrapped `pane run`
DONE_SENTINEL = "MC-DONE"  # completion claim from a worker (section 4 rule 6)
DEFAULT_TIMEOUT_S = 30

# 2.3: an injected prompt must never contain a string the supervisor matches on, or the
# prompt's own echo can satisfy the match. A live run failed to reproduce the collision
# because Claude Code's TUI does not retain injected text, which is per-CLI rendering
# rather than a guarantee. Enforced here so no caller has to remember it.
#
# What is banned is the sentinel *with a nonce beside it*, which is exactly what the
# supervisor matches. The bare word is allowed, and has to be: section 4 rule 6 says the
# literal lives in MACHINE.md, the agent reads it from the file, and the per-task prompt
# supplies only the nonce. Banning the bare word would leave no channel by which an agent
# could ever learn what to print. This is the nonce earning its keep a second time: it
# correlates a status line to one attempt, and it makes an echo of MACHINE.md unmatchable.
MATCHABLE = re.compile(r"\b(?:MC-EXIT|MC-DONE)\s+[0-9a-f]{4,}\b")


class HerdrError(RuntimeError):
    def __init__(self, code, message, args_):
        self.code, self.message, self.args_ = code, message, args_
        super().__init__(f"{code}: {message}")


class SentinelInPrompt(ValueError):
    """A prompt carrying a matchable sentinel would let its own echo satisfy the match."""


class CommandFailed(RuntimeError):
    """A `pane run` whose MC-EXIT line was missing or non-zero (2.3: every pane run is checked)."""

    def __init__(self, exit_code, pane_id, command, excerpt=""):
        self.exit_code, self.pane_id, self.command, self.excerpt = exit_code, pane_id, command, excerpt
        super().__init__(f"exit {exit_code} in {pane_id}: {command}")


@dataclasses.dataclass(frozen=True)
class Pane:
    pane_id: str
    cwd: str | None = None
    agent: str | None = None
    agent_status: str = "unknown"
    workspace_id: str | None = None

    @classmethod
    def of(cls, raw):
        return cls(
            pane_id=raw["pane_id"],
            cwd=raw.get("cwd"),
            agent=raw.get("agent"),
            agent_status=raw.get("agent_status", "unknown"),
            workspace_id=raw.get("workspace_id"),
        )


@dataclasses.dataclass(frozen=True)
class Agent:
    name: str
    pane_id: str
    agent_status: str
    launch_pending: bool = False
    cwd: str | None = None

    @property
    def blocked_at_startup(self):
        """Distinguishes a first-run trust prompt from a mid-task block (2.3, measured)."""
        return self.agent_status == "blocked" and self.launch_pending

    @classmethod
    def of(cls, raw):
        return cls(
            name=raw.get("name", ""),
            pane_id=raw["pane_id"],
            agent_status=raw.get("agent_status", "unknown"),
            launch_pending=bool(raw.get("launch_pending")),
            cwd=raw.get("cwd"),
        )


def new_nonce():
    return secrets.token_hex(4)


def wrap(command, nonce):
    """Wrap a shell command so its exit code reaches the buffer.

    A bare `exit N` inside the command terminates the pane's own shell and destroys the
    pane; that was measured, not theorised. The braces keep the exit status without
    ending the shell.
    """
    return f'{{ {command} ; }} ; printf "{SENTINEL} {nonce} %d\\n" "$?"'


class Herdr:
    def __init__(self, binary="herdr", runner=None, timeout=DEFAULT_TIMEOUT_S):
        self.binary, self.timeout = binary, timeout
        self._run = runner or self._subprocess

    def _subprocess(self, args, timeout):
        done = subprocess.run(
            [self.binary, *args], capture_output=True, text=True, timeout=timeout
        )
        return done.returncode, done.stdout, done.stderr

    def _text(self, args, timeout=None):
        code, out, err = self._run(args, timeout or self.timeout)
        if code != 0 and not out:
            raise HerdrError("cli_failed", err.strip() or f"exit {code}", args)
        return out

    def _json(self, args, timeout=None):
        out = self._text(args, timeout)
        try:
            payload = json.loads(out)
        except json.JSONDecodeError:
            raise HerdrError("not_json", out.strip()[:200], args) from None
        if "error" in payload:
            raise HerdrError(payload["error"].get("code", "?"), payload["error"].get("message", ""), args)
        return payload.get("result", payload)

    # Panes ------------------------------------------------------------------

    def panes(self):
        return [Pane.of(p) for p in self._json(["pane", "list"])["panes"]]

    def split(self, parent, cwd, direction="down", focus=False):
        """Returns the new pane. The plan assumed `--print-id`, which does not exist; the
        split's own JSON carries the id. `--cwd` lives here because `agent start` has none,
        so a worker's working directory is a property of its pane."""
        args = ["pane", "split", parent, "--direction", direction, "--cwd", str(cwd)]
        args.append("--focus" if focus else "--no-focus")
        return Pane.of(self._json(args)["pane"])

    def close(self, pane_id):
        self._json(["pane", "close", pane_id])

    def rename(self, pane_id, label):
        """Display label only. `pane get <label>` returns pane_not_found, so the supervisor
        keeps its own name-to-id map (2.3, measured; plan 7)."""
        self._json(["pane", "rename", pane_id, label])

    def read(self, pane_id, lines=60, source="recent-unwrapped"):
        """Plain text, not JSON."""
        return self._text(["pane", "read", pane_id, "--source", source, "--lines", str(lines)])

    def process_info(self, pane_id):
        """The plan assumed `pane info --pid`. Real command, and it returns the tree."""
        return self._json(["pane", "process-info", "--pane", pane_id])["process_info"]

    def send_keys(self, pane_id, *keys):
        self._json(["pane", "send-keys", pane_id, *keys])

    def send_text(self, pane_id, text):
        """The only way to answer a blocked agent, since `agent prompt` refuses one."""
        if MATCHABLE.search(text):
            raise SentinelInPrompt(f"text carries a matchable sentinel: {text[:80]!r}")
        self._json(["pane", "send-text", pane_id, text])

    def wait_output(self, pane_id, pattern, timeout_ms, source="recent-unwrapped"):
        """Blocking regex match returning the matched line. Replaces the poll loop in plan 6."""
        result = self._json(
            ["pane", "wait-output", pane_id, "--regex", pattern,
             "--source", source, "--timeout", str(timeout_ms)],
            timeout=timeout_ms / 1000 + 5,
        )
        return result["matched_line"]

    def run_checked(self, pane_id, command, timeout_ms=60000, cwd=None):
        """Run a command in a pane and return its real exit code.

        `pane run` reports nothing, so the command is wrapped with a nonce-tagged status
        line and the buffer is waited on. The nonce is a correlation token: without it a
        stale status line from an earlier run is indistinguishable from this one's.
        """
        nonce = new_nonce()
        full = f"cd {shlex.quote(str(cwd))} && {command}" if cwd else command
        self._json(["pane", "run", pane_id, wrap(full, nonce)])
        try:
            line = self.wait_output(pane_id, rf"{SENTINEL} {nonce} [0-9]+", timeout_ms)
        except HerdrError as exc:
            raise CommandFailed(None, pane_id, command, f"no status line: {exc}") from None
        return int(line.split()[-1])

    def run_or_raise(self, pane_id, command, **kw):
        code = self.run_checked(pane_id, command, **kw)
        if code != 0:
            raise CommandFailed(code, pane_id, command, self.read(pane_id, lines=40))
        return code

    # Agents -----------------------------------------------------------------

    def agent(self, target):
        return Agent.of(self._json(["agent", "get", target])["agent"])

    def start_agent(self, name, kind, pane_id, timeout_ms=25000):
        """Start an agent in an existing pane at its shell prompt.

        There is no `--cwd`; the pane carries it. A clean pane commonly returns
        `agent_not_ready` because the CLI blocks on a first-run trust prompt, which is a
        normal outcome rather than a failure, so the agent's state is returned either way
        and the caller decides. The prompt is once per path, not once per dispatch.
        """
        try:
            self._json(["agent", "start", name, "--kind", kind,
                        "--pane", pane_id, "--timeout", str(timeout_ms)],
                       timeout=timeout_ms / 1000 + 5)
        except HerdrError as exc:
            if exc.code not in ("agent_not_ready", "agent_blocked"):
                raise
        return self.agent(name)

    def prompt(self, target, text, until="working", timeout_ms=15000):
        """Submit a prompt, waiting for the state transition.

        Two measured behaviours are enforced here. A blocked agent rejects submission with
        `agent_blocked` before any input is sent, so callers must unblock first. And the
        call returns before the agent leaves idle, so `--wait` is passed rather than left
        to the caller to remember; without it a supervisor polling immediately reads idle,
        finds no sentinel, and spends a nudge on every dispatch.
        """
        if MATCHABLE.search(text):
            raise SentinelInPrompt("prompt carries a matchable sentinel; its echo could satisfy the match")
        return self._json(
            ["agent", "prompt", target, text, "--wait", "--until", until, "--timeout", str(timeout_ms)],
            timeout=timeout_ms / 1000 + 5,
        )

    def send_keys_agent(self, target, *keys):
        self._json(["agent", "send-keys", target, *keys])
