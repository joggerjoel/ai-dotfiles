#!/usr/bin/env python3
"""
test_packet.py - Unit Test Suite for task packet assembly
"""

import json
import pathlib
import tempfile
import unittest

import packet

FACT = {
    "claim": "httpx 0.28 removed the app= shortcut",
    "observed_via": "python3 -c 'import httpx; print(httpx.__version__)'",
    "exit_code": 0, "excerpt": "0.28.1", "observed_at": "2026-09-13T10:00:00+00:00",
}
BLOCKER = {
    "need": "SUPABASE_SERVICE_KEY is unset in the work tree",
    "blocks": "Implement token refresh",
    "observed_via": "printenv SUPABASE_SERVICE_KEY",
    "exit_code": 1, "excerpt": "(unset)", "observed_at": "2026-09-13T10:00:00+00:00",
}


# Every real packet carries the machine context, because that is the only channel by
# which a worker learns the completion sentinel (section 4 rule 6).
MACHINE = ("MACHINE.md", "Use uv, never pip.\n"
                         "Signal completion by printing MC-DONE followed by the nonce supplied.")


def minimal(**kw):
    base = dict(goal="Make ./verify.sh pass", remaining=["Implement retry logic"],
                tree="/tmp/wt", nonce="7f3a21ab", instructions=[MACHINE])
    base.update(kw)
    return packet.build(**base)


class TestContents(unittest.TestCase):

    def test_carries_the_goal_and_remaining_work(self):
        text = minimal()
        self.assertIn("Make ./verify.sh pass", text)
        self.assertIn("Implement retry logic", text)

    def test_first_attempt_says_so_rather_than_omitting_the_section(self):
        self.assertIn("first attempt", minimal())

    def test_carries_the_verifier_failure_verbatim(self):
        text = minimal(verification={
            "command": "./verify.sh", "exit_code": 1,
            "excerpt": "AssertionError: '($5.00)' != '-$5.00'"})
        self.assertIn("exit 1", text)
        self.assertIn("'($5.00)' != '-$5.00'", text)

    def test_repo_instructions_are_named_by_source(self):
        text = minimal()
        self.assertIn("Repo instructions (MACHINE.md)", text)
        self.assertIn("Use uv, never pip.", text)

    def test_facts_carry_their_evidence_not_just_the_claim(self):
        text = minimal(facts=[FACT])
        self.assertIn("httpx 0.28 removed", text)
        self.assertIn("0.28.1", text)

    def test_blockers_name_what_they_block(self):
        self.assertIn("Implement token refresh", minimal(blockers=[BLOCKER]))

    def test_the_nonce_is_present_without_the_sentinel_beside_it(self):
        text = minimal()
        self.assertIn("7f3a21ab", text)
        self.assertNotIn("MC-DONE 7f3a21ab", text)


class TestInvariants(unittest.TestCase):

    def test_blocker_instruction_is_always_present(self):
        # Measured: a packet without it produces "done" against a red verifier and silence.
        self.assertIn("UNREACHABLE", minimal())
        self.assertIn("blockers.json", minimal(facts=[FACT], blockers=[BLOCKER]))

    def test_evidence_only_rule_is_stated_to_the_worker(self):
        self.assertIn("never what you think it means", minimal())

    def test_a_goalless_packet_is_refused(self):
        for empty in ("", "   ", None):
            with self.assertRaises(packet.PacketError):
                minimal(goal=empty)

    def test_pairing_the_sentinel_with_a_nonce_is_refused(self):
        with self.assertRaises(packet.PacketError) as caught:
            minimal(goal="print MC-DONE 7f3a21ab when finished")
        self.assertIn("2.3", str(caught.exception))

    def test_referring_to_a_previous_attempt_is_refused(self):
        with self.assertRaises(packet.PacketError) as caught:
            minimal(instructions=[MACHINE, ("notes", "The previous agent tried a decorator.")])
        self.assertIn("10.2", str(caught.exception))

    def test_a_packet_that_never_names_the_sentinel_is_refused(self):
        # Otherwise the worker cannot signal completion, which at runtime is
        # indistinguishable from a worker that finished silently.
        with self.assertRaises(packet.PacketError) as caught:
            minimal(instructions=[("SPEC.md", "no mention of signalling here")])
        self.assertIn("cannot learn", str(caught.exception))

    def test_the_bare_sentinel_and_the_nonce_coexist_apart(self):
        text = minimal()
        self.assertIn("MC-DONE", text)
        self.assertIn("7f3a21ab", text)
        self.assertNotIn("MC-DONE 7f3a21ab", text)

    def test_a_packet_is_built_not_mutated(self):
        first = minimal()
        second = minimal(facts=[FACT])
        self.assertNotIn("httpx", first)
        self.assertIn("httpx", second)


class TestValidatedHarvest(unittest.TestCase):

    def write(self, payload):
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        tmp.write(payload if isinstance(payload, str) else json.dumps(payload))
        tmp.close()
        return pathlib.Path(tmp.name)

    def test_missing_file_is_empty_not_an_error(self):
        records, problems = packet.load_validated("/nonexistent/facts.json", "facts")
        self.assertEqual((records, problems), ([], []))

    def test_valid_records_load(self):
        records, problems = packet.load_validated(
            self.write({"schema": 1, "facts": [FACT]}), "facts")
        self.assertEqual(problems, [])
        self.assertEqual(records[0]["claim"], FACT["claim"])

    def test_reasoning_is_rejected_by_the_skill_validator(self):
        bad = dict(FACT, claim="I think the auth architecture is wrong")
        records, problems = packet.load_validated(
            self.write({"schema": 1, "facts": [bad]}), "facts")
        self.assertEqual(records, [])
        self.assertTrue(any("first-person belief" in p for p in problems))

    def test_a_failing_file_is_dropped_whole_not_partially_salvaged(self):
        good, bad = FACT, dict(FACT, claim="probably a race")
        records, problems = packet.load_validated(
            self.write({"schema": 1, "facts": [good, bad]}), "facts")
        self.assertEqual(records, [], "one bad record must drop the file, not just itself")
        self.assertTrue(problems)

    def test_malformed_json_is_reported_not_raised(self):
        records, problems = packet.load_validated(self.write("{not json"), "facts")
        self.assertEqual(records, [])
        self.assertIn("not valid JSON", problems[0])

    def test_the_validator_is_the_skill_copy_not_a_duplicate(self):
        self.assertTrue(packet.VALIDATOR.exists())
        self.assertIn("amnesiac-workers", str(packet.VALIDATOR))


if __name__ == "__main__":
    unittest.main()
