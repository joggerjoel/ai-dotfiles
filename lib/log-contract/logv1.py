# log-contract-v1 helper 1.0.0
"""Single-file Python helper for log contract v1 (guides/log-contract-v1.md).

Copy this file into a project; update by copying it again. Standard library
only; runs on Python 3.8 and later.
"""
import datetime
import json
import os
import re
import secrets
import sys
import traceback

VERSION = "1.0.0"
LEVELS = ("debug", "info", "warn", "error")
_EVENT_RE = re.compile(r"^[a-z0-9_]+(\.[a-z0-9_]+)*$")
_NEWLINES_RE = re.compile(r"\s*[\r\n]+\s*")


def iso_with_offset(now=None):
    """ISO 8601 local time with milliseconds and a numeric offset."""
    now = now or datetime.datetime.now().astimezone()
    return now.isoformat(timespec="milliseconds")


def _one_line(text):
    return _NEWLINES_RE.sub(" ", str(text)).strip()


def _error_object(err):
    if isinstance(err, BaseException):
        out = {"type": type(err).__name__, "message": _one_line(err)}
        code = getattr(err, "errno", None)
        if code is None:
            code = getattr(err, "code", None)
        if code is not None:
            out["code"] = code
        if err.__traceback__ is not None:
            out["stack"] = "".join(traceback.format_exception(type(err), err, err.__traceback__))
        return out
    return {"type": type(err).__name__, "message": _one_line(err)}


def _default_proc():
    if os.environ.get("PROCRUN_PROC"):
        return os.environ["PROCRUN_PROC"]
    script = sys.argv[0] if sys.argv and sys.argv[0] else "python"
    return os.path.splitext(os.path.basename(script))[0] or "python"


class Logger:
    """proc defaults to PROCRUN_PROC, then the script name; run_id defaults to
    PROCRUN_RUN_ID, then 128 random bits; stream defaults to stderr."""

    def __init__(self, proc=None, run_id=None, stream=None):
        self.proc = proc or _default_proc()
        self.run_id = run_id or os.environ.get("PROCRUN_RUN_ID") or secrets.token_hex(16)
        self._stream = stream

    def log(self, level, event, msg, fields=None, err=None):
        if level not in LEVELS:
            raise ValueError("logv1: unknown level %r" % (level,))
        if not _EVENT_RE.match(event or ""):
            raise ValueError("logv1: event must look like db.lock_timeout, got %r" % (event,))
        record = {
            "v": 1,
            "ts": iso_with_offset(),
            "level": level,
            "proc": self.proc,
            "run_id": self.run_id,
            "event": event,
            "msg": _one_line(msg),
        }
        if fields:
            record["fields"] = fields
        if err is not None:
            record["err"] = _error_object(err)
        stream = self._stream or sys.stderr
        stream.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
        stream.flush()

    def debug(self, event, msg, fields=None, err=None):
        self.log("debug", event, msg, fields, err)

    def info(self, event, msg, fields=None, err=None):
        self.log("info", event, msg, fields, err)

    def warn(self, event, msg, fields=None, err=None):
        self.log("warn", event, msg, fields, err)

    def error(self, event, msg, fields=None, err=None):
        self.log("error", event, msg, fields, err)
