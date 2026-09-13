#!/usr/bin/env python3
"""
test_taskqueue.py - Unit Test Suite for the supervisor-owned queue and work-unit ids
"""

import unittest

import ids
import taskqueue as q

QUEUE = """# Sprint

Some prose the supervisor must not touch.

- [ ] Implement token refresh
  - **Description**: refresh before expiry
  allow-test-changes: the timeout assertion is wrong
- [>] Fix auth timeout <!-- id:fix-auth-timeout-9f2a1c -->
- [x] Add health endpoint
- [!] Migrate to v3

See [the runbook](https://example.com/runbook) for context.
"""


class TestParsing(unittest.TestCase):

    def setUp(self):
        self.q = q.parse(QUEUE)

    def test_finds_every_mark(self):
        self.assertEqual(
            [t.mark for t in self.q.tasks],
            [q.Mark.PENDING, q.Mark.IN_PROGRESS, q.Mark.DONE, q.Mark.QUARANTINED],
        )

    def test_identity_comes_from_the_line(self):
        self.assertEqual(self.q.tasks[1].task_id, "fix-auth-timeout-9f2a1c")
        self.assertEqual(self.q.tasks[1].title, "Fix auth timeout")

    def test_continuations_attach_to_their_task(self):
        self.assertEqual(len(self.q.tasks[0].continuations), 2)
        self.assertIsNone(self.q.tasks[1].allow_test_changes)

    def test_allow_test_changes_is_read_from_a_continuation(self):
        self.assertEqual(
            self.q.tasks[0].allow_test_changes, "the timeout assertion is wrong"
        )

    def test_a_markdown_link_bullet_is_prose_not_a_corrupt_line(self):
        # Taken literally 2.5's "^- \\[ with an unknown mark escalates" would quarantine
        # the runbook link in the fixture above.
        self.assertEqual(len(self.q.tasks), 4)

    def test_unknown_mark_escalates(self):
        with self.assertRaises(q.UnknownMark):
            q.parse("- [?] Who knows\n")

    def test_missing_file_is_no_work(self):
        self.assertEqual(q.load("/nonexistent/TODO.md").status(), "no-work")

    def test_empty_queue_is_no_work(self):
        self.assertEqual(q.parse("# Nothing here\n").status(), "no-work")


class TestDispatchOrder(unittest.TestCase):

    def test_in_progress_wins_so_a_restart_reconciles(self):
        parsed = q.parse(QUEUE)
        self.assertEqual(parsed.next_dispatchable().task_id, "fix-auth-timeout-9f2a1c")
        self.assertEqual(parsed.status(), "in-progress")

    def test_pending_is_next_once_nothing_is_in_progress(self):
        parsed = q.parse("- [ ] First\n- [ ] Second\n")
        self.assertEqual(parsed.next_dispatchable().title, "First")

    def test_quarantined_lines_do_not_block_done(self):
        self.assertEqual(q.parse("- [x] Done\n- [!] Skipped\n").status(), "done")


class TestMarkTransitions(unittest.TestCase):

    def test_pending_to_in_progress_requires_an_id(self):
        parsed = q.parse("- [ ] First\n")
        with self.assertRaises(ValueError):
            parsed.set_mark(parsed.tasks[0], q.Mark.IN_PROGRESS)

    def test_done_is_terminal(self):
        parsed = q.parse("- [x] Done\n")
        with self.assertRaises(q.IllegalTransition):
            parsed.set_mark(parsed.tasks[0], q.Mark.PENDING)

    def test_pending_cannot_jump_to_done(self):
        # Skipping IN_PROGRESS would mark a task complete with no verifier run.
        parsed = q.parse("- [ ] First\n")
        with self.assertRaises(q.IllegalTransition):
            parsed.set_mark(parsed.tasks[0], q.Mark.DONE)

    def test_marking_in_progress_writes_the_id_into_the_line(self):
        parsed = q.parse("- [ ] Fix auth timeout\n")
        parsed.set_mark(parsed.tasks[0], q.Mark.IN_PROGRESS, task_id="fix-auth-timeout-9f2a1c")
        self.assertIn("- [>] Fix auth timeout <!-- id:fix-auth-timeout-9f2a1c -->", parsed.render())

    def test_rewrite_preserves_prose_and_continuations(self):
        parsed = q.parse(QUEUE)
        parsed.set_mark(parsed.tasks[1], q.Mark.DONE)
        out = parsed.render()
        self.assertIn("Some prose the supervisor must not touch.", out)
        self.assertIn("allow-test-changes: the timeout assertion is wrong", out)
        self.assertIn("- [x] Fix auth timeout <!-- id:fix-auth-timeout-9f2a1c -->", out)

    def test_other_indices_survive_a_rewrite(self):
        parsed = q.parse(QUEUE)
        parsed.set_mark(parsed.tasks[1], q.Mark.DONE)
        parsed.set_mark(parsed.tasks[3], q.Mark.PENDING)
        self.assertIn("- [ ] Migrate to v3", parsed.render())
        self.assertIn("- [x] Fix auth timeout", parsed.render())

    def test_round_trip_without_changes_is_byte_identical(self):
        self.assertEqual(q.parse(QUEUE).render(), QUEUE)


class TestTaskIds(unittest.TestCase):

    def test_slug_shape(self):
        self.assertEqual(ids.slugify("Fix Auth (Timeout!)"), "fix-auth-timeout")

    def test_slug_is_truncated_without_a_trailing_hyphen(self):
        slug = ids.slugify("Refactor the entire billing subsystem now please", max_len=20)
        self.assertLessEqual(len(slug), 20)
        self.assertFalse(slug.endswith("-"))

    def test_minted_id_passes_the_assertion(self):
        ids.assert_task_id(ids.mint_task_id("Fix auth timeout"))

    def test_unsluggable_title_raises_rather_than_inventing(self):
        with self.assertRaises(ids.UnsluggableTitle):
            ids.mint_task_id("!!! ???")

    def test_refuses_to_interpolate_a_traversal(self):
        for hostile in ["../../etc/passwd", "a; rm -rf /", "Fix Auth", "", None]:
            with self.assertRaises(ValueError):
                ids.assert_task_id(hostile)

    def test_incident_id_shape(self):
        ids.assert_incident_id("a1b2c3d4e5f6-20260912-9f2a1c")
        with self.assertRaises(ValueError):
            ids.assert_incident_id("not-an-incident")


if __name__ == "__main__":
    unittest.main()
