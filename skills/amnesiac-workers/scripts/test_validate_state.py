#!/usr/bin/env python3
"""
test_validate_state.py - Unit Test Suite for the amnesiac-worker state validator
"""

import unittest

from validate_state import Invalid, validate


def fact(**overrides):
    record = {
        "claim": "test_refresh_expired_token exits 1",
        "observed_via": "./verify.sh",
        "exit_code": 1,
        "excerpt": "FAILED tests/auth/refresh.py::test_refresh_expired_token",
        "observed_at": "2026-09-12T21:14:00-04:00",
    }
    record.update(overrides)
    return {"schema": 1, "facts": [record]}


def blocker(**overrides):
    record = {
        "need": "SUPABASE_SERVICE_KEY is unset in the work tree",
        "blocks": "Implement retry logic",
        "observed_via": "printenv SUPABASE_SERVICE_KEY",
        "exit_code": 1,
        "excerpt": "",
        "observed_at": "2026-09-12T21:14:00-04:00",
    }
    record.update(overrides)
    return {"schema": 1, "blockers": [record]}


def state(**overrides):
    doc = {
        "schema": 1,
        "unit_id": "fix-auth-timeout-9f2a1c",
        "attempt": 7,
        "retry_budget": 3,
        "verification": {
            "command": "./verify.sh",
            "exit_code": 1,
            "excerpt": "test_refresh_expired_token expected 401, received 500",
        },
    }
    doc.update(overrides)
    return doc


class TestAcceptsEvidence(unittest.TestCase):

    def test_well_formed_fact(self):
        self.assertEqual(validate(fact()), [])

    def test_well_formed_state(self):
        self.assertEqual(validate(state()), [])

    def test_verification_may_be_null_before_the_first_run(self):
        self.assertEqual(validate(state(attempt=1, verification=None)), [])

    def test_blocker_excerpt_may_be_empty_only_when_it_is_not(self):
        doc = blocker(excerpt="")
        self.assertTrue(any("excerpt is empty" in e for e in validate(doc)))

    def test_blocker_with_output(self):
        self.assertEqual(validate(blocker(excerpt="(unset)")), [])

    def test_empty_collection_is_valid(self):
        self.assertEqual(validate({"schema": 1, "facts": []}), [])


class TestRejectsReasoning(unittest.TestCase):

    def assertRejected(self, claim, label):
        errors = validate(fact(claim=claim))
        self.assertTrue(
            any(label in e for e in errors),
            f"expected {label!r} rejection for {claim!r}, got {errors}",
        )

    def test_first_person_belief(self):
        self.assertRejected("I think the auth architecture is wrong", "first-person belief")

    def test_hedge(self):
        self.assertRejected("The token is probably expired", "hedge")

    def test_seems(self):
        self.assertRejected("The refresh path seems to drop the header", "hedge")

    def test_recommendation(self):
        self.assertRejected("We should move refresh into middleware", "recommendation")

    def test_recommend_verb(self):
        self.assertRejected("Recommend rewriting the retry loop", "recommendation")

    def test_cross_attempt_carryover(self):
        self.assertRejected("The previous agent tried a decorator", "cross-attempt carryover")

    def test_opinion(self):
        self.assertRejected("In my opinion the client is at fault", "opinion")

    def test_speculative_causation(self):
        self.assertRejected("The 500 is caused by a missing await", "speculative causation")

    def test_design_judgment(self):
        self.assertRejected("The current design is fragile", "design judgment")

    def test_speculation(self):
        self.assertRejected("This might be a race", "speculation")

    def test_blocker_need_is_policed_too(self):
        errors = validate(blocker(need="I think we need a service key", excerpt="x"))
        self.assertTrue(any("first-person belief" in e for e in errors))

    def test_narrative_length(self):
        errors = validate(fact(claim="the endpoint returns 500. " * 20))
        self.assertTrue(any("limit 200" in e for e in errors))

    def test_blocker_need_gets_more_room_than_a_claim(self):
        # Measured from a live run: a two-test contradiction needs 276 chars to
        # name both parties and what each produced. 200 rejected a correct record.
        self.assertEqual(validate(blocker(need="x" * 276, excerpt="out")), [])

    def test_blocker_need_is_still_capped(self):
        errors = validate(blocker(need="x" * 401, excerpt="out"))
        self.assertTrue(any("limit 400" in e for e in errors))


class TestClosedSchema(unittest.TestCase):

    def test_extra_field_is_rejected(self):
        doc = fact()
        doc["facts"][0]["notes"] = "long rambling analysis of the auth flow"
        errors = validate(doc)
        self.assertTrue(any("unpermitted field(s): notes" in e for e in errors))

    def test_missing_evidence_is_rejected(self):
        doc = fact()
        del doc["facts"][0]["observed_via"]
        errors = validate(doc)
        self.assertTrue(any("missing required field(s): observed_via" in e for e in errors))

    def test_claim_without_output_is_rejected(self):
        errors = validate(fact(excerpt="   "))
        self.assertTrue(any("is a belief" in e for e in errors))

    def test_empty_command_is_rejected(self):
        errors = validate(fact(observed_via=""))
        self.assertTrue(any("names the command" in e for e in errors))

    def test_state_rejects_git_derived_fields(self):
        doc = state()
        doc["commit"] = "a14cb82"
        doc["changes_since_start"] = ["src/auth/refresh.ts"]
        errors = validate(doc)
        self.assertTrue(any("derive from git" in e for e in errors))

    def test_bool_is_not_an_int(self):
        errors = validate(fact(exit_code=True))
        self.assertTrue(any("is bool, expected int" in e for e in errors))

    def test_bad_timestamp(self):
        errors = validate(fact(observed_at="last tuesday"))
        self.assertTrue(any("not ISO-8601" in e for e in errors))

    def test_excerpt_is_capped(self):
        errors = validate(fact(excerpt="x" * 2001))
        self.assertTrue(any("limit 2000" in e for e in errors))

    def test_ledger_is_bounded(self):
        doc = fact()
        doc["facts"] = doc["facts"] * 51
        errors = validate(doc)
        self.assertTrue(any("transcript by another name" in e for e in errors))

    def test_attempt_is_one_indexed(self):
        errors = validate(state(attempt=0))
        self.assertTrue(any("one-indexed" in e for e in errors))


class TestDiscrimination(unittest.TestCase):

    def test_ambiguous_document(self):
        with self.assertRaises(Invalid):
            validate({"schema": 1, "facts": [], "blockers": []})

    def test_unrecognized_document(self):
        with self.assertRaises(Invalid):
            validate({"schema": 1, "handoff": "the previous agent believed..."})

    def test_non_object_top_level(self):
        with self.assertRaises(Invalid):
            validate([])

    def test_schema_version_mismatch(self):
        errors = validate({"schema": 99, "facts": []})
        self.assertTrue(any("expected 1" in e for e in errors))

    def test_collection_must_be_an_array(self):
        errors = validate({"schema": 1, "facts": {"a": 1}})
        self.assertTrue(any("expected array" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
