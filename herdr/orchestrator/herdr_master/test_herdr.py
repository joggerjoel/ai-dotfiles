#!/usr/bin/env python3
"""
test_herdr.py - Unit Test Suite for the herdr CLI client

Canned responses are the shapes captured from herdr 0.9.0 during the plan 2.3 probe,
not invented ones. A fake runner stands in for the subprocess so the suite needs no
running server.
"""

import json
import unittest

import herdr as h

SPLIT = json.dumps({"id": "cli:pane:split", "result": {"type": "pane_info", "pane": {
    "pane_id": "w9:pB", "cwd": "/private/tmp", "agent_status": "unknown", "workspace_id": "w9"}}})
AGENT_BLOCKED = json.dumps({"id": "cli:agent:get", "result": {"type": "agent_info", "agent": {
    "name": "mc-w1", "pane_id": "w9:pD", "agent_status": "blocked",
    "launch_pending": True, "cwd": "/private/tmp/wt"}}})
AGENT_IDLE = json.dumps({"id": "cli:agent:get", "result": {"type": "agent_info", "agent": {
    "name": "mc-w1", "pane_id": "w9:pD", "agent_status": "idle",
    "launch_pending": None, "cwd": "/private/tmp/wt"}}})
NOT_READY = json.dumps({"id": "cli:agent:start", "error": {
    "code": "agent_not_ready", "message": "agent mc-w1 is blocked during startup"}})
NOT_FOUND = json.dumps({"id": "cli:pane:read", "error": {
    "code": "pane_not_found", "message": "pane mc-worker not found"}})
OK = json.dumps({"id": "cli:pane:close", "result": {"type": "ok"}})
PROC = json.dumps({"id": "cli:pane:process_info", "result": {"type": "pane_process_info",
    "process_info": {"shell_pid": 60822, "foreground_process_group_id": 60822,
                     "foreground_processes": [{"pid": 60822, "name": "zsh", "argv": ["-zsh"]}]}}})


class Fake:
    """Records every argv and replies per subcommand, defaulting to a bare ok."""

    def __init__(self, replies):
        self.replies, self.calls = replies, []

    def argv(self, n=-1):
        return self.calls[n]


def _wire(fake):
    def runner(args, timeout):
        fake.calls.append(args)
        return fake.replies.get(" ".join(args[:2]), (0, OK, ""))
    return h.Herdr(runner=runner), fake


def make(**replies):
    return _wire(Fake({k.replace("_", "-"): (0, v, "") for k, v in replies.items()}))


class TestTransport(unittest.TestCase):

    def test_error_code_is_preserved(self):
        cli, _ = make(**{"pane process-info": NOT_FOUND})
        with self.assertRaises(h.HerdrError) as caught:
            cli.process_info("nope")
        self.assertEqual(caught.exception.code, "pane_not_found")

    def test_non_json_from_a_json_command_is_an_error(self):
        cli, _ = make(**{"pane process-info": "not json at all"})
        with self.assertRaises(h.HerdrError) as caught:
            cli.process_info("w9:pB")
        self.assertEqual(caught.exception.code, "not_json")

    def test_text_commands_are_not_json_parsed(self):
        cli, _ = make(**{"pane read": "> ls\nfoo.py\n"})
        self.assertIn("foo.py", cli.read("w9:pB"))

    def test_process_info_exposes_the_tree(self):
        cli, _ = make(**{"pane process-info": PROC})
        info = cli.process_info("w9:pB")
        self.assertEqual(info["shell_pid"], 60822)
        self.assertEqual(info["foreground_processes"][0]["pid"], 60822)


class TestPanes(unittest.TestCase):

    def test_split_returns_the_new_id_without_print_id(self):
        cli, fake = make(**{"pane split": SPLIT})
        pane = cli.split("w9:pA", cwd="/tmp/wt")
        self.assertEqual(pane.pane_id, "w9:pB")
        self.assertNotIn("--print-id", fake.argv())

    def test_split_carries_cwd_because_agent_start_cannot(self):
        cli, fake = make(**{"pane split": SPLIT})
        cli.split("w9:pA", cwd="/tmp/wt")
        argv = fake.argv()
        self.assertIn("--cwd", argv)
        self.assertEqual(argv[argv.index("--cwd") + 1], "/tmp/wt")

    def test_split_does_not_steal_focus_by_default(self):
        cli, fake = make(**{"pane split": SPLIT})
        cli.split("w9:pA", cwd="/tmp")
        self.assertIn("--no-focus", fake.argv())


class TestRunChecked(unittest.TestCase):

    def test_wrapper_never_uses_a_bare_exit(self):
        # A bare `exit N` terminates the pane's shell and destroys the pane (measured).
        wrapped = h.wrap("./verify.sh", "abc123")
        self.assertNotRegex(wrapped, r"(^|;)\s*exit\s")
        self.assertTrue(wrapped.startswith("{ "))

    def test_exit_code_comes_from_the_sentinel_not_the_cli(self):
        cli, fake = make(**{"pane wait-output": json.dumps(
            {"result": {"matched_line": "MC-EXIT zz 7", "pane_id": "w9:pB"}})})
        self.assertEqual(cli.run_checked("w9:pB", "./verify.sh"), 7)

    def test_nonce_is_unique_per_call(self):
        cli, fake = make(**{"pane wait-output": json.dumps(
            {"result": {"matched_line": "MC-EXIT zz 0"}})})
        cli.run_checked("w9:pB", "true")
        first = [a for a in fake.argv(0) if "MC-EXIT" in a][0]
        cli.run_checked("w9:pB", "true")
        second = [a for a in fake.calls[2] if "MC-EXIT" in a][0]
        self.assertNotEqual(first, second)

    def test_cwd_is_quoted_into_the_command(self):
        cli, fake = make(**{"pane wait-output": json.dumps(
            {"result": {"matched_line": "MC-EXIT zz 0"}})})
        cli.run_checked("w9:pB", "./verify.sh", cwd="/tmp/a dir")
        self.assertIn("'/tmp/a dir'", fake.argv(0)[-1])

    def test_missing_status_line_is_a_failure_not_a_pass(self):
        cli, _ = make(**{"pane wait-output": json.dumps({"error": {"code": "timeout", "message": "no match"}})})
        with self.assertRaises(h.CommandFailed) as caught:
            cli.run_checked("w9:pB", "./verify.sh")
        self.assertIsNone(caught.exception.exit_code)

    def test_run_or_raise_raises_on_non_zero(self):
        cli, _ = make(**{
            "pane wait-output": json.dumps({"result": {"matched_line": "MC-EXIT zz 1"}}),
            "pane read": "FAILED (failures=3)",
        })
        with self.assertRaises(h.CommandFailed) as caught:
            cli.run_or_raise("w9:pB", "./verify.sh")
        self.assertEqual(caught.exception.exit_code, 1)
        self.assertIn("failures=3", caught.exception.excerpt)


class TestAgents(unittest.TestCase):

    def test_start_tolerates_the_startup_block(self):
        cli, _ = make(**{"agent start": NOT_READY, "agent get": AGENT_BLOCKED})
        agent = cli.start_agent("mc-w1", "claude", "w9:pD")
        self.assertTrue(agent.blocked_at_startup)

    def test_start_passes_no_cwd(self):
        cli, fake = make(**{"agent start": OK, "agent get": AGENT_IDLE})
        cli.start_agent("mc-w1", "claude", "w9:pD")
        self.assertNotIn("--cwd", fake.argv(0))

    def test_a_mid_task_block_is_not_a_startup_block(self):
        cli, _ = make(**{"agent get": json.dumps({"result": {"agent": {
            "name": "mc-w1", "pane_id": "w9:pD", "agent_status": "blocked", "launch_pending": None}}})})
        self.assertFalse(cli.agent("mc-w1").blocked_at_startup)

    def test_prompt_always_waits(self):
        cli, fake = make(**{"agent prompt": OK})
        cli.prompt("mc-w1", "do the thing")
        self.assertIn("--wait", fake.argv())

    def test_prompt_refuses_a_matchable_sentinel(self):
        cli, _ = make(**{"agent prompt": OK})
        with self.assertRaises(h.SentinelInPrompt):
            cli.prompt("mc-w1", "when done print MC-DONE abc123")

    def test_send_text_refuses_a_matchable_sentinel(self):
        cli, _ = make()
        with self.assertRaises(h.SentinelInPrompt):
            cli.send_text("w9:pB", "echo MC-EXIT 7f3a21ab 0")

    def test_send_text_allows_an_answer_that_merely_mentions_the_word(self):
        cli, fake = make()
        cli.send_text("w9:pB", "yes, use the MC-EXIT convention")
        self.assertEqual(fake.argv()[:2], ["pane", "send-text"])

    def test_the_bare_sentinel_is_allowed_so_machine_md_can_carry_it(self):
        # Section 4 rule 6 puts the literal in MACHINE.md and the nonce in the prompt.
        # Banning the bare word would leave no channel for an agent to learn it.
        cli, fake = make(**{"agent prompt": OK})
        cli.prompt("mc-w1", "Signal completion with the MC-DONE sentinel and the nonce below.")
        self.assertIn("--wait", fake.argv())

    def test_sentinel_with_a_nonce_is_still_refused(self):
        cli, _ = make(**{"agent prompt": OK})
        with self.assertRaises(h.SentinelInPrompt):
            cli.prompt("mc-w1", "print MC-DONE 7f3a21ab when finished")

    def test_ordinary_prompt_text_is_allowed(self):
        cli, fake = make(**{"agent prompt": OK})
        cli.prompt("mc-w1", "make ./verify.sh pass; do not edit the tests")
        self.assertIn("agent", fake.argv()[0])


if __name__ == "__main__":
    unittest.main()
