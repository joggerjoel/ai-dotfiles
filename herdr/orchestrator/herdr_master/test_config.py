#!/usr/bin/env python3
"""
test_config.py - Unit Test Suite for the MACHINE.md schema parser

The primary fixture is read out of the plan itself rather than copied here. A copy
would let the parser and the specification drift apart silently, which is the exact
failure the roadmap rewrite just cleaned up.
"""

import dataclasses
import pathlib
import re
import unittest

import config

PLAN = pathlib.Path(__file__).resolve().parents[1] / "master-control-herdr-plan.md"


def spec_fixture():
    text = PLAN.read_text(encoding="utf-8")
    section = text.split("## 4. Machine-Specific Context Specification")[1]
    return re.search(r"```markdown\n(.*?)```", section, re.S).group(1)


class TestParsesTheSpecVerbatim(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.raw = spec_fixture()
        cls.cfg = config.parse(cls.raw)

    def test_the_fixture_really_came_from_the_plan(self):
        self.assertIn("Machine Context & Autonomy Rules", self.raw)

    def test_identity(self):
        self.assertEqual(self.cfg.machine_id, "mac-studio-01")

    def test_a_comment_containing_backticks_is_not_the_value(self):
        # The Profile line ends "# must match a 7 registered profile, or `local`".
        self.assertEqual(self.cfg.profile, "worker-studio")

    def test_paths_and_branch(self):
        self.assertEqual(self.cfg.base_branch, "main")
        self.assertEqual(self.cfg.working_directory, "~/projects/billing")
        self.assertEqual(self.cfg.worktree_root, "~/projects/.worktrees")

    def test_panes(self):
        self.assertEqual(self.cfg.worker_pane, "billing-worker")
        self.assertEqual(self.cfg.verify_pane, "billing-verify")
        self.assertEqual(self.cfg.shell_pane, "billing-shell")

    def test_verification_commands_keep_their_flags(self):
        self.assertEqual(self.cfg.test_cmd, "cargo test")
        self.assertEqual(self.cfg.lint_cmd, "cargo clippy -- -D warnings")

    def test_numeric_values_survive_their_trailing_comments(self):
        self.assertEqual(self.cfg.test_timeout_ms, 600000)
        self.assertEqual(self.cfg.stall_idle_seconds, 900)

    def test_timezone(self):
        self.assertEqual(self.cfg.require_timezone(), "America/Toronto")

    def test_exhaustion_pattern_round_trips(self):
        pattern = self.cfg.exhaustion_pattern("claude")
        self.assertIn("running out of context", pattern)
        re.compile(config.DELIMITED.sub(r"\1", pattern))

    def test_dependency_policy_is_a_list(self):
        self.assertEqual(self.cfg.allowed_registries, ("crates.io",))
        self.assertEqual(self.cfg.allowed_installers, ("cargo add",))


class TestShippedTemplate(unittest.TestCase):
    """The template teaches the format, so an unparseable template is a broken template.

    The previous MACHINE.template.md was prose with none of section 4's keys in it, so
    anyone following it produced a config the supervisor could not read.
    """

    def test_the_shipped_template_parses(self):
        cfg = config.load(PLAN.parent / "MACHINE.template.md")
        self.assertEqual(cfg.base_branch, "main")
        self.assertEqual(cfg.verify_pane, "your-repo-verify")
        self.assertEqual(cfg.test_cmd, "python3 -m unittest discover -q")
        self.assertEqual(cfg.allowed_registries, ("pypi.org",))
        self.assertIn("running out of context", cfg.exhaustion_pattern("claude"))
        self.assertEqual(cfg.require_timezone(), "America/Toronto")


class TestAbsenceHasAConsequence(unittest.TestCase):

    def minimal(self, **drop):
        fields = {
            "Machine ID": "m1", "Profile": "local", "Working Directory": "~/p",
            "Base Branch": "main", "Worktree Root": "~/w",
        }
        subs = {"worker_pane": "w", "verify_pane": "v", "shell_pane": "s", "test_cmd": "pytest"}
        for key in drop:
            fields.pop(drop[key], None)
            subs.pop(drop[key], None)
        lines = [f"- **{k}**: {v}" for k, v in fields.items()]
        lines += ["- **Panes**:"] + [f"  - `{k}`: {v}" for k, v in subs.items()]
        return "\n".join(lines) + "\n"

    def test_minimal_config_parses(self):
        cfg = config.parse(self.minimal())
        self.assertEqual(cfg.test_timeout_ms, config.TEST_TIMEOUT_MS)
        self.assertIsNone(cfg.lint_cmd)

    def test_missing_base_branch_names_its_consequence(self):
        with self.assertRaises(config.MachineConfigError) as caught:
            config.parse(self.minimal(a="Base Branch"))
        self.assertIn("dispatch escalates", str(caught.exception))

    def test_missing_verify_pane_blocks_completion(self):
        with self.assertRaises(config.MachineConfigError) as caught:
            config.parse(self.minimal(a="verify_pane"))
        self.assertIn("never be marked done", str(caught.exception))

    def test_missing_test_cmd_escalates_rather_than_passing(self):
        with self.assertRaises(config.MachineConfigError) as caught:
            config.parse(self.minimal(a="test_cmd"))
        self.assertIn("rather than passing", str(caught.exception))

    def test_every_problem_is_reported_at_once(self):
        with self.assertRaises(config.MachineConfigError) as caught:
            config.parse("# empty\n")
        self.assertGreaterEqual(len(caught.exception.problems), 9)

    def test_absent_timezone_defers_its_consequence(self):
        cfg = config.parse(self.minimal())
        self.assertIsNone(cfg.timezone)
        with self.assertRaises(config.MachineConfigError):
            cfg.require_timezone()

    def test_unlisted_agent_kind_escalates(self):
        with self.assertRaises(config.MachineConfigError):
            config.parse(self.minimal()).exhaustion_pattern("codex")

    def test_non_integer_timeout_is_a_problem_not_a_default(self):
        with self.assertRaises(config.MachineConfigError) as caught:
            config.parse(self.minimal() + "- **Verification**:\n  - `test_timeout_ms`: soon\n")
        self.assertIn("expected an integer", str(caught.exception))

    def test_uncompilable_exhaustion_pattern_is_caught_at_parse(self):
        broken = self.minimal() + "- **Agent kinds**:\n  - `claude`: `/context (unclosed/i`\n"
        with self.assertRaises(config.MachineConfigError) as caught:
            config.parse(broken)
        self.assertIn("does not compile", str(caught.exception))

    def test_config_is_immutable(self):
        cfg = config.parse(self.minimal())
        with self.assertRaises(dataclasses.FrozenInstanceError):
            cfg.test_cmd = "true"


if __name__ == "__main__":
    unittest.main()
