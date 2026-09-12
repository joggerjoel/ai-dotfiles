#!/usr/bin/env python3
"""
herdr_unblocker.py - Autonomous Terminal Unblocker for Herdr Workloads

Monitors agent terminal panes managed by Herdr. When an agent enters the 'blocked'
state waiting for user input, this service classifies the prompt and dispatches
the appropriate response (y/N, Enter, pagers) or escalates dangerous operations.

Zero external dependencies - runs on standard Python 3.10+.
"""

import argparse
import dataclasses
from enum import Enum
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple


class ActionType(str, Enum):
    SEND_KEYS = "SEND_KEYS"
    SEND_PROMPT = "SEND_PROMPT"
    WAIT = "WAIT"
    ESCALATE_DANGEROUS = "ESCALATE_DANGEROUS"
    LOOP_DETECTED = "LOOP_DETECTED"
    NO_ACTION = "NO_ACTION"


@dataclasses.dataclass
class PromptDecision:
    action: ActionType
    keys: List[str] = dataclasses.field(default_factory=list)
    prompt_text: Optional[str] = None
    reason: str = ""
    matched_pattern: Optional[str] = None
    confidence: float = 0.0
    is_dangerous: bool = False


class HerdrClient:
    """Interface to the local Herdr CLI binary."""

    def __init__(self, binary_path: str = "herdr"):
        self.binary_path = binary_path

    def _run(self, args: List[str], timeout: Optional[float] = None) -> Tuple[int, str, str]:
        cmd = [self.binary_path] + args
        try:
            res = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout
            )
            return res.returncode, res.stdout.strip(), res.stderr.strip()
        except subprocess.TimeoutExpired:
            return 124, "", "command_timed_out"
        except FileNotFoundError:
            return 127, "", f"herdr binary '{self.binary_path}' not found in PATH"

    def is_server_running(self) -> bool:
        code, out, _ = self._run(["status"])
        return code == 0 and "status: running" in out.lower()

    def list_agents(self) -> List[Dict[str, Any]]:
        """List active agents in Herdr."""
        code, out, err = self._run(["agent", "list"])
        if code != 0:
            return []
        
        agents: List[Dict[str, Any]] = []
        # Attempt JSON parse if returned, else parse table output
        try:
            data = json.loads(out)
            if isinstance(data, list):
                return data
            if isinstance(data, dict) and "result" in data:
                return data["result"].get("agents", [])
        except json.JSONDecodeError:
            pass

        # Text table parsing fallback
        lines = out.splitlines()
        if len(lines) > 1:
            for line in lines[1:]:
                parts = line.split()
                if parts:
                    agents.append({"name": parts[0], "status": parts[1] if len(parts) > 1 else "unknown"})
        return agents

    def get_agent_status(self, agent_name: str) -> Optional[str]:
        """Fetch the lifecycle status (idle, working, blocked, done, unknown) of an agent."""
        code, out, _ = self._run(["agent", "get", agent_name])
        if code != 0:
            return None
        try:
            data = json.loads(out)
            agent_obj = data.get("result", {}).get("agent", {})
            return agent_obj.get("status")
        except json.JSONDecodeError:
            # Match status in key-value text output
            m = re.search(r"status:\s*(\w+)", out, re.I)
            if m:
                return m.group(1).lower()
        return None

    def read_buffer(self, agent_name: str, lines: int = 60, source: str = "recent-unwrapped") -> str:
        """Read recent terminal output from an agent pane."""
        code, out, _ = self._run(["agent", "read", agent_name, "--source", source, "--lines", str(lines)])
        if code != 0 and source != "visible":
            # Fallback to visible viewport for alternate screen / TUI
            code, out, _ = self._run(["agent", "read", agent_name, "--source", "visible", "--lines", str(lines)])
        return out if code == 0 else ""

    def wait_agent(self, agent_name: str, until: str = "blocked", timeout_ms: int = 30000) -> int:
        """Wait until an agent enters the requested state."""
        code, _, _ = self._run(["agent", "wait", agent_name, "--until", until, "--timeout", str(timeout_ms)])
        return code

    def send_keys(self, agent_name: str, keys: List[str]) -> bool:
        """Send specific key inputs to the agent pane."""
        code, _, err = self._run(["agent", "send-keys", agent_name] + keys)
        return code == 0

    def prompt_agent(self, agent_name: str, prompt: str, wait: bool = False) -> bool:
        """Submit text prompt to the agent pane."""
        args = ["agent", "prompt", agent_name, prompt]
        if wait:
            args.append("--wait")
        code, _, _ = self._run(args)
        return code == 0


class PromptClassifier:
    """Analyzes terminal buffer text to determine safe unblocking actions."""

    # Patterns indicating high-risk operations that MUST NOT be auto-confirmed
    DANGEROUS_PATTERNS = [
        re.compile(r"rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|--recursive\s+--force)", re.I),
        re.compile(r"\bDROP\s+(TABLE|DATABASE|SCHEMA)\b", re.I),
        re.compile(r"\bmkfs\b", re.I),
        re.compile(r"\bgit\s+reset\s+--hard\b", re.I),
        re.compile(r"\b(AWS_SECRET_ACCESS_KEY|ANTHROPIC_API_KEY|OPENAI_API_KEY)\b", re.I),
        re.compile(r"\bDELETE\s+FROM\s+\w+\s*(?:;|$)", re.I),  # unqualified DELETE
    ]

    # Simple interactive confirmation patterns
    YES_PATTERNS = [
        (re.compile(r"\[y/N\]", re.I), ["y", "enter"], "Standard [y/N] prompt"),
        (re.compile(r"\[Y/n\]", re.I), ["y", "enter"], "Standard [Y/n] prompt"),
        (re.compile(r"\([yY]/[nN]\)"), ["y", "enter"], "Standard (y/n) prompt"),
        (re.compile(r"\[yes/no\]", re.I), ["yes", "enter"], "Standard [yes/no] prompt"),
        (re.compile(r"Do you want to (?:proceed|continue)\??", re.I), ["y", "enter"], "Proceed confirmation question"),
        (re.compile(r"Are you sure you want to continue\??", re.I), ["y", "enter"], "Are you sure question"),
        (re.compile(r"Allow (?:command execution|tool call|access|file creation)\??", re.I), ["y", "enter"], "Tool execution permission"),
        (re.compile(r"Apply these changes\??", re.I), ["y", "enter"], "Diff application prompt"),
        (re.compile(r"Allow \w+ to run:?.*\[y/n\]", re.I), ["y", "enter"], "Agent command approval"),
    ]

    # Pager or continuation prompts
    ENTER_PATTERNS = [
        (re.compile(r"Press\s+\[?Enter\]?\s+to\s+continue", re.I), ["enter"], "Press Enter prompt"),
        (re.compile(r"Press\s+\[?Return\]?\s+to\s+continue", re.I), ["enter"], "Press Return prompt"),
    ]

    # Pagers like 'less' / git diffs
    PAGER_QUIT_PATTERNS = [
        (re.compile(r"\n\(END\)\s*$", re.M), ["q"], "Pager (END) prompt - quit to resume"),
        (re.compile(r"\n:\s*$", re.M), ["q"], "Pager (:) prompt - quit to resume"),
    ]

    @classmethod
    def classify(cls, buffer: str) -> PromptDecision:
        if not buffer or not buffer.strip():
            return PromptDecision(action=ActionType.NO_ACTION, reason="Empty buffer")

        # Check tail of the buffer (last 30 lines are most relevant)
        lines = buffer.strip().splitlines()
        tail = "\n".join(lines[-30:])

        # 1. Safety Check: Verify no destructive command is awaiting confirmation
        for danger_regex in cls.DANGEROUS_PATTERNS:
            if danger_regex.search(tail):
                return PromptDecision(
                    action=ActionType.ESCALATE_DANGEROUS,
                    is_dangerous=True,
                    reason="Potentially destructive command detected awaiting confirmation",
                    matched_pattern=danger_regex.pattern,
                    confidence=1.0
                )

        # 2. Check for Pager / Less output
        for regex, keys, reason in cls.PAGER_QUIT_PATTERNS:
            if regex.search(tail):
                return PromptDecision(
                    action=ActionType.SEND_KEYS,
                    keys=keys,
                    reason=reason,
                    matched_pattern=regex.pattern,
                    confidence=0.95
                )

        # 3. Check for Yes/No confirmations
        for regex, keys, reason in cls.YES_PATTERNS:
            m = regex.search(tail)
            if m:
                return PromptDecision(
                    action=ActionType.SEND_KEYS,
                    keys=keys,
                    reason=reason,
                    matched_pattern=regex.pattern,
                    confidence=0.90
                )

        # 4. Check for Enter / Return prompts
        for regex, keys, reason in cls.ENTER_PATTERNS:
            m = regex.search(tail)
            if m:
                return PromptDecision(
                    action=ActionType.SEND_KEYS,
                    keys=keys,
                    reason=reason,
                    matched_pattern=regex.pattern,
                    confidence=0.90
                )

        return PromptDecision(
            action=ActionType.NO_ACTION,
            reason="No known auto-unblock pattern matched in active terminal tail"
        )


class AntiLoopTracker:
    """Prevents infinite loops by tracking buffer hashes per agent."""

    def __init__(self, max_repeats: int = 3):
        self.max_repeats = max_repeats
        self._history: Dict[str, List[str]] = {}

    def _normalize_and_hash(self, buffer: str) -> str:
        # Strip trailing whitespace and volatile timestamp-like numbers to get stable hash
        cleaned = re.sub(r"\d{1,2}:\d{2}(?::\d{2})?", "", buffer)
        cleaned = re.sub(r"\s+", " ", cleaned).strip()
        return hashlib.sha256(cleaned.encode("utf-8")).hexdigest()

    def check_and_record(self, agent_name: str, buffer: str) -> bool:
        """
        Returns True if the buffer is novel or safe.
        Returns False if the same buffer has repeated >= max_repeats (loop detected).
        """
        buf_hash = self._normalize_and_hash(buffer)
        if agent_name not in self._history:
            self._history[agent_name] = []

        history = self._history[agent_name]
        history.append(buf_hash)

        # Keep history window bounded
        if len(history) > 10:
            history.pop(0)

        # Count occurrences in recent history
        recent_count = history[-self.max_repeats:].count(buf_hash)
        if recent_count >= self.max_repeats:
            return False  # Loop detected
        return True

    def reset(self, agent_name: str):
        if agent_name in self._history:
            self._history[agent_name].clear()


class UnblockerDaemon:
    """Orchestrates the monitoring loop over target agents."""

    def __init__(
        self,
        client: HerdrClient,
        anti_loop: AntiLoopTracker,
        dry_run: bool = False,
        verbose: bool = False
    ):
        self.client = client
        self.anti_loop = anti_loop
        self.dry_run = dry_run
        self.verbose = verbose

    def log(self, msg: str, level: str = "INFO"):
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        prefix = {
            "INFO": "\033[94m[*]\033[0m",
            "SUCCESS": "\033[92m[✓]\033[0m",
            "WARN": "\033[93m[!]\033[0m",
            "ALERT": "\033[91m[ALERT]\033[0m",
            "DRY": "\033[95m[DRY-RUN]\033[0m"
        }.get(level, "[*]")
        print(f"{timestamp} {prefix} {msg}")

    def inspect_agent(self, agent_name: str) -> Optional[PromptDecision]:
        status = self.client.get_agent_status(agent_name)
        if self.verbose:
            self.log(f"Agent '{agent_name}' status: {status or 'unreachable'}")

        if status != "blocked":
            return None

        buffer = self.client.read_buffer(agent_name, lines=40)
        if not buffer:
            return None

        # Anti-loop verification
        if not self.anti_loop.check_and_record(agent_name, buffer):
            self.log(f"Infinite loop detected for agent '{agent_name}'. Disengaging auto-unblocker.", level="ALERT")
            return PromptDecision(
                action=ActionType.LOOP_DETECTED,
                reason="Buffer unchanged across consecutive turns. Human intervention required."
            )

        decision = PromptClassifier.classify(buffer)
        return decision

    def act_on_decision(self, agent_name: str, decision: PromptDecision):
        if decision.action == ActionType.NO_ACTION:
            if self.verbose:
                self.log(f"Agent '{agent_name}' blocked, but no automated pattern matched.", level="INFO")
            return

        if decision.action == ActionType.ESCALATE_DANGEROUS:
            self.log(f"Dangerous operation flagged on '{agent_name}': {decision.reason}", level="ALERT")
            self.notify_macos(f"Agent {agent_name} requires review: dangerous operation detected!")
            return

        if decision.action == ActionType.LOOP_DETECTED:
            self.notify_macos(f"Agent {agent_name} stuck in repetitive loop. Check terminal.")
            return

        if decision.action == ActionType.SEND_KEYS:
            keys_str = " ".join(decision.keys)
            if self.dry_run:
                self.log(f"Would send keys '{keys_str}' to '{agent_name}' ({decision.reason})", level="DRY")
            else:
                self.log(f"Unblocking '{agent_name}': sending keys [{keys_str}] ({decision.reason})", level="SUCCESS")
                success = self.client.send_keys(agent_name, decision.keys)
                if not success:
                    self.log(f"Failed to send keys to '{agent_name}'", level="WARN")

    def notify_macos(self, message: str, title: str = "Herdr Master Control"):
        """Send a native macOS notification banner."""
        if sys.platform == "darwin":
            script = f'display notification "{message}" with title "{title}"'
            subprocess.run(["osascript", "-e", script], capture_output=True)

    def run_once(self, agent_name: Optional[str] = None) -> int:
        """Perform a single inspection sweep across target agent(s)."""
        agents = [agent_name] if agent_name else [a.get("name") for a in self.client.list_agents() if a.get("name")]
        if not agents or agents == [None]:
            if self.verbose:
                self.log("No running agents found to inspect.")
            return 0

        unblocked_count = 0
        for name in agents:
            if not name:
                continue
            decision = self.inspect_agent(name)
            if decision:
                self.act_on_decision(name, decision)
                if decision.action == ActionType.SEND_KEYS:
                    unblocked_count += 1
        return unblocked_count

    def watch(self, agent_name: Optional[str] = None, interval: float = 3.0):
        """Continuously monitor agent(s) until stopped."""
        self.log(f"Starting unblocker watch loop (interval: {interval}s). Press Ctrl+C to stop.")
        try:
            while True:
                self.run_once(agent_name)
                time.sleep(interval)
        except KeyboardInterrupt:
            self.log("Watch loop stopped by user.")


def main():
    parser = argparse.ArgumentParser(
        description="Master Control Herdr Auto-Unblocker",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Check once and exit (for scripting / cron)
  python3 herdr_unblocker.py --check

  # Watch a specific agent in real-time
  python3 herdr_unblocker.py --agent worker-1 --watch

  # Dry-run across all agents without sending keystrokes
  python3 herdr_unblocker.py --watch --dry-run --verbose
        """
    )
    parser.add_argument("--agent", "-a", help="Specific agent name to supervise (default: inspect all)")
    parser.add_argument("--watch", "-w", action="store_true", help="Run continuously in a watch loop")
    parser.add_argument("--check", "-c", action="store_true", help="Perform a single sweep and exit (default)")
    parser.add_argument("--interval", "-i", type=float, default=3.0, help="Polling interval in seconds (default: 3.0)")
    parser.add_argument("--dry-run", action="store_true", help="Log actions without sending keystrokes")
    parser.add_argument("--verbose", "-v", action="store_true", help="Enable verbose debug logging")
    parser.add_argument("--herdr-bin", default="herdr", help="Path to herdr binary (default: 'herdr')")

    args = parser.parse_args()

    client = HerdrClient(binary_path=args.herdr_bin)
    anti_loop = AntiLoopTracker()
    daemon = UnblockerDaemon(client, anti_loop, dry_run=args.dry_run, verbose=args.verbose)

    if args.watch:
        daemon.watch(agent_name=args.agent, interval=args.interval)
    else:
        unblocked = daemon.run_once(agent_name=args.agent)
        if args.verbose:
            print(f"Sweep complete. Unblocked {unblocked} actions.")


if __name__ == "__main__":
    main()
