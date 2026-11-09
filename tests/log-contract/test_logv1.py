"""Tests for lib/log-contract/logv1.py. Run by scripts/log-contract.test.sh."""
import io
import json
import os
import re
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib", "log-contract"))
import logv1  # noqa: E402

ISO_OFFSET_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}$")


def capture(**kwargs):
    stream = io.StringIO()
    return logv1.Logger(stream=stream, **kwargs), stream


class LoggerTest(unittest.TestCase):
    def test_writes_one_v1_record_per_line(self):
        log, stream = capture(proc="demo", run_id="abc")
        log.info("job.start", "Starting", fields={"rows": 3})
        text = stream.getvalue()
        self.assertEqual(text.count("\n"), 1)
        record = json.loads(text)
        self.assertEqual(
            list(record), ["v", "ts", "level", "proc", "run_id", "event", "msg", "fields"])
        self.assertEqual(record["v"], 1)
        self.assertRegex(record["ts"], ISO_OFFSET_RE)
        self.assertEqual((record["proc"], record["run_id"]), ("demo", "abc"))
        self.assertEqual(record["fields"], {"rows": 3})

    def test_takes_run_id_and_proc_from_procrun(self):
        env = {"PROCRUN_RUN_ID": "f" * 32, "PROCRUN_PROC": "dice-onsale-notify"}
        with mock.patch.dict(os.environ, env):
            log, stream = capture()
            log.warn("notify.slow", "slow")
        record = json.loads(stream.getvalue())
        self.assertEqual((record["run_id"], record["proc"]), ("f" * 32, "dice-onsale-notify"))

    def test_generates_run_id_outside_procrun(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("PROCRUN_RUN_ID", None)
            log, _ = capture()
        self.assertRegex(log.run_id, r"^[0-9a-f]{32}$")

    def test_one_line_msg_and_err_with_stack(self):
        log, stream = capture(proc="demo")
        try:
            raise OSError(110, "Connection\ntimed out")
        except OSError as exc:
            log.error("db.connect_timeout", "Could not\nconnect", err=exc)
        text = stream.getvalue()
        self.assertEqual(text.count("\n"), 1)
        record = json.loads(text)
        self.assertEqual(record["msg"], "Could not connect")
        self.assertEqual(record["err"]["type"], "OSError")
        self.assertEqual(record["err"]["code"], 110)
        self.assertIn("Traceback", record["err"]["stack"])
        self.assertNotIn("fields", record)

    def test_rejects_unknown_level_and_bad_event(self):
        log, _ = capture(proc="demo")
        with self.assertRaisesRegex(ValueError, "unknown level"):
            log.log("fatal", "a.b", "x")
        with self.assertRaisesRegex(ValueError, "event must look like"):
            log.info("Lock Timeout", "x")


if __name__ == "__main__":
    unittest.main()
