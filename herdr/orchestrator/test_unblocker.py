#!/usr/bin/env python3
"""
test_unblocker.py - Unit Test Suite for Herdr Auto-Unblocker
"""

import unittest
from herdr_unblocker import (
    ActionType,
    AntiLoopTracker,
    PromptClassifier,
    PromptDecision,
)


class TestPromptClassifier(unittest.TestCase):

    def test_standard_yes_no_prompts(self):
        cases = [
            ("npm install requested package uuid.\nDo you want to proceed? [y/N] ", ["y", "enter"]),
            ("Found 3 outdated dependencies.\nContinue? [Y/n] ", ["y", "enter"]),
            ("Agent requested tool permission.\nAllow command execution? (y/n) ", ["y", "enter"]),
            ("File diff generated for src/index.ts.\nApply these changes? ", ["y", "enter"]),
            ("Creating directory /tmp/build.\nAre you sure you want to continue? ", ["y", "enter"]),
            ("Allow claude to run: pytest tests/ [y/n] ", ["y", "enter"]),
        ]
        for buffer, expected_keys in cases:
            decision = PromptClassifier.classify(buffer)
            self.assertEqual(decision.action, ActionType.SEND_KEYS, f"Failed on: {buffer}")
            self.assertEqual(decision.keys, expected_keys, f"Wrong keys for: {buffer}")
            self.assertFalse(decision.is_dangerous)

    def test_press_enter_prompts(self):
        cases = [
            ("Initial setup complete.\nPress [Enter] to continue: ", ["enter"]),
            ("Installation finished successfully.\nPress Enter to continue ", ["enter"]),
            ("Press return to continue... ", ["enter"]),
        ]
        for buffer, expected_keys in cases:
            decision = PromptClassifier.classify(buffer)
            self.assertEqual(decision.action, ActionType.SEND_KEYS, f"Failed on: {buffer}")
            self.assertEqual(decision.keys, expected_keys)

    def test_pager_prompts(self):
        pager_end = "commit 1a2b3c4d\nAuthor: dev\nDate: Mon\n\n    Add feature\n(END)"
        decision = PromptClassifier.classify(pager_end)
        self.assertEqual(decision.action, ActionType.SEND_KEYS)
        self.assertEqual(decision.keys, ["q"])

        pager_colon = "Line 1\nLine 2\nLine 3\n:"
        decision2 = PromptClassifier.classify(pager_colon)
        self.assertEqual(decision2.action, ActionType.SEND_KEYS)
        self.assertEqual(decision2.keys, ["q"])

    def test_dangerous_commands_are_blocked(self):
        dangerous_cases = [
            "Agent wants to run: rm -rf /data/cache\nDo you want to proceed? [y/N] ",
            "Executing query: DROP TABLE production_users;\nAre you sure? (y/n) ",
            "Discarding uncommitted changes: git reset --hard HEAD\nConfirm? [y/N] ",
            "Found token: AWS_SECRET_ACCESS_KEY=AKIA... Do you want to continue? [y/N]",
            "DELETE FROM orders;\nProceed with execution? [y/N] ",
        ]
        for buffer in dangerous_cases:
            decision = PromptClassifier.classify(buffer)
            self.assertEqual(
                decision.action,
                ActionType.ESCALATE_DANGEROUS,
                f"Dangerous action was NOT escalated for: {buffer}"
            )
            self.assertTrue(decision.is_dangerous)

    def test_benign_logs_produce_no_action(self):
        normal_logs = [
            "Compiling src/core.rs...\nFinished `dev` profile [unoptimized + debuginfo] target(s) in 1.45s",
            "Tests: 42 passed, 42 total\nTime: 3.12s\nDONE",
            "",
            "   \n\t\n  ",
        ]
        for buffer in normal_logs:
            decision = PromptClassifier.classify(buffer)
            self.assertEqual(decision.action, ActionType.NO_ACTION)


class TestAntiLoopTracker(unittest.TestCase):

    def setUp(self):
        self.tracker = AntiLoopTracker(max_repeats=3)

    def test_novel_buffers_pass(self):
        self.assertTrue(self.tracker.check_and_record("agent-1", "Prompt 1: [y/N]"))
        self.assertTrue(self.tracker.check_and_record("agent-1", "Prompt 2: [y/N]"))
        self.assertTrue(self.tracker.check_and_record("agent-1", "Prompt 3: [y/N]"))

    def test_repeated_buffers_trigger_loop_detection(self):
        stuck_prompt = "Failed to run command. Retry? [y/N]"
        self.assertTrue(self.tracker.check_and_record("agent-1", stuck_prompt))
        self.assertTrue(self.tracker.check_and_record("agent-1", stuck_prompt))
        # 3rd identical occurrence should trip the circuit breaker
        self.assertFalse(self.tracker.check_and_record("agent-1", stuck_prompt))

    def test_timestamp_normalization(self):
        # Even if timestamps differ, repeated prompts should still be detected
        t1 = "11:20:01 [WARN] Retry connection? [y/N]"
        t2 = "11:20:05 [WARN] Retry connection? [y/N]"
        t3 = "11:20:09 [WARN] Retry connection? [y/N]"
        self.assertTrue(self.tracker.check_and_record("agent-1", t1))
        self.assertTrue(self.tracker.check_and_record("agent-1", t2))
        self.assertFalse(self.tracker.check_and_record("agent-1", t3))


if __name__ == "__main__":
    unittest.main()
