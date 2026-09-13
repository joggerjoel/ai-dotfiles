#!/usr/bin/env python3
"""
test_store.py - Unit Test Suite for supervisor-owned state and the action log
"""

import json
import os
import stat
import tempfile
import unittest

import store


class StoreCase(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = store.Store(root=self.tmp.name + "/hm")
        self.unit = self.store.open_unit(
            "fix-auth-9f2a1c", lane="todo", profile="local", title="Fix auth timeout",
            branch="task/fix-auth-9f2a1c", tree="/tmp/wt", base_branch="main",
        )

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()


class TestUnits(StoreCase):

    def test_open_is_idempotent_so_a_restart_does_not_reset_progress(self):
        self.store.begin_attempt("fix-auth-9f2a1c", "n1")
        again = self.store.open_unit(
            "fix-auth-9f2a1c", lane="todo", profile="local", title="Fix auth timeout",
            branch="task/fix-auth-9f2a1c", tree="/tmp/wt", base_branch="main",
        )
        self.assertEqual(again["attempt"], 1)
        self.assertEqual(again["retry_budget"], 3)

    def test_attempts_are_one_indexed_and_increment(self):
        self.assertEqual(self.store.begin_attempt("fix-auth-9f2a1c", "n1"), 1)
        self.assertEqual(self.store.begin_attempt("fix-auth-9f2a1c", "n2"), 2)

    def test_unknown_unit_raises(self):
        with self.assertRaises(KeyError):
            self.store.begin_attempt("no-such-unit", "n1")


class TestBudget(StoreCase):

    def close(self, attempt, code):
        self.store.close_attempt(
            "fix-auth-9f2a1c", attempt, command="./verify.sh", exit_code=code,
            excerpt="FAILED (failures=1)" if code else "OK",
        )

    def test_budget_decrements_only_on_failure(self):
        self.close(self.store.begin_attempt("fix-auth-9f2a1c", "n1"), 1)
        self.assertEqual(self.store.unit("fix-auth-9f2a1c")["retry_budget"], 2)
        self.close(self.store.begin_attempt("fix-auth-9f2a1c", "n2"), 0)
        self.assertEqual(self.store.unit("fix-auth-9f2a1c")["retry_budget"], 2)

    def test_exhaustion_raises_rather_than_dispatching_a_fourth_worker(self):
        for n in range(3):
            self.close(self.store.begin_attempt("fix-auth-9f2a1c", f"n{n}"), 1)
        with self.assertRaises(store.BudgetExhausted):
            self.store.begin_attempt("fix-auth-9f2a1c", "n4")

    def test_last_verification_is_the_most_recent_closed_attempt(self):
        self.close(self.store.begin_attempt("fix-auth-9f2a1c", "n1"), 1)
        self.store.close_attempt(
            "fix-auth-9f2a1c", self.store.begin_attempt("fix-auth-9f2a1c", "n2"),
            command="./verify.sh", exit_code=2, excerpt="second",
        )
        self.assertEqual(self.store.last_verification("fix-auth-9f2a1c")["exit_code"], 2)

    def test_no_verification_before_the_first_close(self):
        self.assertIsNone(self.store.last_verification("fix-auth-9f2a1c"))


class TestPaneMap(StoreCase):

    def test_names_resolve_supervisor_side(self):
        self.store.bind_pane("local", "billing-verify", "w9:pF")
        self.assertEqual(self.store.pane("local", "billing-verify"), "w9:pF")

    def test_rebinding_a_name_replaces_the_id(self):
        self.store.bind_pane("local", "billing-verify", "w9:pF")
        self.store.bind_pane("local", "billing-verify", "w9:pZ")
        self.assertEqual(self.store.pane("local", "billing-verify"), "w9:pZ")

    def test_revalidate_drops_names_aimed_at_dead_panes(self):
        self.store.bind_pane("local", "alive", "w9:pF")
        self.store.bind_pane("local", "dead", "w9:pGONE")
        dropped = self.store.revalidate_panes("local", ["w9:pF", "w9:pA"])
        self.assertEqual(dropped, ["dead"])
        self.assertIsNone(self.store.pane("local", "dead"))
        self.assertEqual(self.store.pane("local", "alive"), "w9:pF")

    def test_revalidate_is_quiet_when_nothing_is_stale(self):
        self.store.bind_pane("local", "alive", "w9:pF")
        self.assertEqual(self.store.revalidate_panes("local", ["w9:pF"]), [])


class TestEscalations(StoreCase):

    def test_open_until_acked(self):
        eid = self.store.escalate("budget_exhausted", "3 attempts spent", "fix-auth-9f2a1c")
        self.assertEqual(len(self.store.open_escalations()), 1)
        self.store.ack(eid, "--retry")
        self.assertEqual(self.store.open_escalations(), [])

    def test_acking_twice_does_not_reopen_or_overwrite(self):
        eid = self.store.escalate("stall", "no output", "fix-auth-9f2a1c")
        self.store.ack(eid, "--retry")
        self.store.ack(eid, "--skip")
        row = self.store.db.execute("SELECT ack FROM escalations WHERE id = ?", (eid,)).fetchone()
        self.assertEqual(row["ack"], "--retry")


class TestRedaction(StoreCase):

    def test_known_token_shapes_are_scrubbed_before_the_write(self):
        self.store.actions.append("probe", detail="using ghp_" + "a" * 36 + " now")
        line = self.store.actions.read()[-1]["detail"]
        self.assertIn(store.REDACTED, line)
        self.assertNotIn("ghp_a", line)

    def test_bearer_and_keyed_values(self):
        self.store.actions.append("probe", a="Authorization: Bearer abcdef0123456789",
                                  b="api_key=supersecretvalue")
        record = self.store.actions.read()[-1]
        self.assertNotIn("abcdef0123456789", record["a"])
        self.assertNotIn("supersecretvalue", record["b"])

    def test_private_key_blocks(self):
        pem = "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----"
        self.store.actions.append("probe", detail=pem)
        self.assertNotIn("AAAA", self.store.actions.read()[-1]["detail"])

    def test_nested_structures_are_scrubbed(self):
        self.store.actions.append("probe", nested={"list": ["token=hunter2secret"]})
        self.assertNotIn("hunter2secret", json.dumps(self.store.actions.read()[-1]))

    def test_exit_codes_and_timings_survive(self):
        # An over-eager redactor that eats digits makes the log useless for the thing it
        # is most often read for.
        self.store.actions.append("attempt_close", exit_code=1, duration_ms=600000)
        record = self.store.actions.read()[-1]
        self.assertEqual(record["exit_code"], 1)
        self.assertEqual(record["duration_ms"], 600000)

    def test_verifier_excerpts_are_scrubbed_on_the_way_into_the_db(self):
        self.store.close_attempt(
            "fix-auth-9f2a1c", self.store.begin_attempt("fix-auth-9f2a1c", "n1"),
            command="./verify.sh", exit_code=1,
            excerpt="connecting with password=hunter2 failed",
        )
        self.assertNotIn("hunter2", self.store.last_verification("fix-auth-9f2a1c")["excerpt"])


class TestPermissions(StoreCase):

    def test_state_is_not_group_or_world_readable(self):
        for path in (self.store.db_path, self.store.actions.path):
            mode = stat.S_IMODE(os.stat(path).st_mode)
            self.assertEqual(mode & 0o077, 0, f"{path} is {oct(mode)}")

    def test_root_directory_is_not_traversable_by_others(self):
        mode = stat.S_IMODE(os.stat(self.store.root).st_mode)
        self.assertEqual(mode & 0o077, 0, oct(mode))


class TestAuditTrail(StoreCase):

    def test_every_state_change_is_recorded(self):
        self.store.set_state("fix-auth-9f2a1c", "dispatched")
        actions = [r["action"] for r in self.store.actions.read()]
        self.assertIn("unit_opened", actions)
        self.assertIn("unit_state", actions)

    def test_records_carry_a_timestamp(self):
        self.assertTrue(self.store.actions.read()[0]["at"].endswith("+00:00"))


if __name__ == "__main__":
    unittest.main()
