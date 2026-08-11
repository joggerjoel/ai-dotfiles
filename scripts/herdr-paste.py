#!/usr/bin/env python3
"""herdr-paste — relay a credential from your hand into a herdr pane.

Some login flows cannot be automated end to end: `claude setup-token` and
codex's device flow hand a human a value that has to be pasted back into a
waiting prompt. This puts that value into a pane on a machine you are not
typing at, and does nothing else.

Design and rationale: references/herdr-paste.md. Read it before changing
anything here — most of what looks fussy is load-bearing, and the reasons are
recorded there rather than repeated in every function.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import unicodedata

SOCKET_PATH = os.environ.get(
    "HERDR_SOCKET_PATH", os.path.expanduser("~/.config/herdr/herdr.sock"))

# The herdr socket protocol this program was written against. Verified at
# startup and again immediately before each write; see the spec.
PROTOCOL = 19

# Exit codes are a contract: a scripted caller branches on them, so each
# failure class gets its own. In particular AMBIGUOUS is not ERR — "the write
# may have landed" and "the write was refused" call for opposite reactions.
EXIT_OK = 0
EXIT_ERR = 1
EXIT_USAGE = 2
EXIT_AMBIGUOUS = 3
EXIT_MISMATCH = 4
EXIT_PROTOCOL = 5
EXIT_PREFLIGHT = 6
EXIT_TIMEOUT = 7


class Rejected(Exception):
    """The payload is not something this relay will transmit."""


class Ambiguous(Exception):
    """The write may have landed. Never retried automatically.

    A device or OAuth code is typically single-use: resending one that did land
    can submit it twice and invalidate the login server-side while the terminal
    shows nothing wrong. So this is its own outcome, not a flavour of failure.
    """


class RpcError(Exception):
    """The daemon refused the request. The value was not delivered."""


class Fatal(Exception):
    """Abort with a specific exit code and a message that names no secret."""

    def __init__(self, code, msg):
        self.code, self.msg = code, msg
        super().__init__(msg)


def preflight():
    """Fail fast when the daemon is not there.

    First gate of all. The protocol check below talks to the daemon itself, so
    running it earlier would let a stale socket hang before anything had a
    chance to report why.
    """
    if not os.path.exists(SOCKET_PATH):
        raise Fatal(EXIT_PREFLIGHT, "no herdr socket at %s" % SOCKET_PATH)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(3.0)
        s.connect(SOCKET_PATH)
        s.close()
    except OSError as e:
        raise Fatal(EXIT_PREFLIGHT, "herdr socket not accepting: %s" % e)


def protocol_check():
    """Refuse to run against a protocol this was not written for.

    Called at startup and again immediately before each write. `serve` sits for
    ten minutes and `send` blocks on a human confirming; a daemon restart
    inside either window would otherwise reach the socket with a stale gate.
    """
    try:
        out = subprocess.run(["herdr", "api", "schema", "--json"],
                             capture_output=True, text=True, timeout=10).stdout
        got = json.loads(out).get("protocol")
    except (OSError, ValueError, AttributeError, subprocess.SubprocessError):
        got = None
    if got != PROTOCOL:
        raise Fatal(EXIT_PROTOCOL,
                    "herdr speaks protocol %s; this expects %s. Re-verify "
                    "pane.send_input's atomicity before raising it." % (got, PROTOCOL))


def rpc(method, params, timeout=5.0):
    """One request, one reply, over the herdr socket.

    The payload is a dict VALUE handed to json.dumps — never interpolated into
    a template. The wire is one JSON object per line, so an interpolated
    newline would start a second request the daemon executes, and an
    interpolated quote would let the payload append its own keys (last-wins
    parsing makes that a well-formed request with an attacker's method).
    """
    req = json.dumps({"id": "paste-1", "method": method, "params": params})
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(SOCKET_PATH)
        s.sendall(req.encode() + b"\n")
        line = s.makefile("rb").readline()
    except socket.timeout:
        raise Ambiguous("no reply within %ss — the write may have landed" % timeout)
    except OSError as e:
        raise Fatal(EXIT_PREFLIGHT, "herdr socket error: %s" % e)
    finally:
        s.close()

    if not line:
        # EOF without a reply. The daemon may have acted before closing, so
        # this is ambiguous, not an error — calling it "not delivered" would be
        # exactly the misreport the ambiguous outcome exists to prevent.
        raise Ambiguous("connection closed with no reply — may have landed")

    reply = json.loads(line)
    if "error" in reply:
        raise RpcError(reply["error"].get("message", "unknown error"))
    return reply


def describe(ch):
    """Name a character for an error message without ever showing the value.

    The offending character is part of a credential, so it is identified by
    codepoint and Unicode name rather than printed.
    """
    try:
        return unicodedata.name(ch)
    except ValueError:
        return "U+%04X" % ord(ch)


def validate(value):
    """Reject anything that is not a plausible bearer credential.

    Reject, never sanitise: silently altering a credential produces a login
    failure nobody can explain, and the operator cannot see the value to work
    out what happened.

    The rule is codepoints in U+0020..U+007E. Bearer tokens, device codes and
    OAuth codes are ASCII by construction, so anything outside that range is a
    sign something other than a credential is being relayed. Two classes matter
    especially, and neither is caught by JSON encoding:

      * newlines — the wire format is one JSON object per line, and a pane at a
        plain shell prompt is not in bracketed-paste mode, so an embedded
        newline becomes a submitted command line;
      * control and format characters — escape sequences reach the terminal
        whatever the JSON validity, and category Cf (bidi overrides,
        zero-width) can forge what a human sees at the confirmation prompt.

    Codepoints, not bytes: the value arrives as a str, and the two only
    coincide inside ASCII anyway.
    """
    if not value:
        raise Rejected("empty value")
    for ch in value:
        o = ord(ch)
        if o < 0x20 or o == 0x7F:
            raise Rejected("control character not allowed: %s" % describe(ch))
        if o > 0x7E:
            raise Rejected(
                "only printable ASCII is allowed; found %s" % describe(ch))


def cmd_validate(_args):
    """Internal verb: the payload rules, exercised without a socket or a pane.

    Reads the candidate on stdin. Never argv — argv is world-readable through
    `ps` for the lifetime of the process, which is the whole reason this
    program exists rather than a call to `herdr pane run`.
    """
    try:
        validate(sys.stdin.read())
    except Rejected as e:
        print("refused: %s" % e, file=sys.stderr)
        return EXIT_ERR
    return EXIT_OK


def cmd_rpc(args):
    """Internal verb: drive one write end to end, for the transport tests.

    --raw-text skips validation on purpose, so the encoder can be proven
    against inputs the validator refuses. Testing it through the validator
    would exercise a path production never takes.
    """
    text = sys.stdin.read() if args.raw_text else "probe"
    if not args.raw_text:
        validate(text)
    preflight()
    protocol_check()
    rpc("pane.send_input",
        {"pane_id": args.pane or "w1:p1", "text": text, "keys": ["enter"]},
        timeout=args.timeout)
    return EXIT_OK


def build_parser():
    ap = argparse.ArgumentParser(
        prog="herdr-paste.py",
        description="Relay a credential into a herdr pane.")
    sub = ap.add_subparsers(dest="verb")
    sub.add_parser("list", help="panes you can paste into (read-only)")
    sub.add_parser("send", help="pick, paste, confirm, deliver")
    sub.add_parser("serve", help="the phone-friendly page; tailnet only")
    sub.add_parser("_validate", help=argparse.SUPPRESS)
    p_rpc = sub.add_parser("_rpc", help=argparse.SUPPRESS)
    p_rpc.add_argument("--timeout", type=float, default=5.0)
    p_rpc.add_argument("--raw-text", action="store_true")
    p_rpc.add_argument("--pane")
    return ap


def main(argv=None):
    ap = build_parser()
    args = ap.parse_args(argv)

    if args.verb is None:
        ap.print_usage(sys.stderr)
        return EXIT_USAGE

    handlers = {"_validate": cmd_validate, "_rpc": cmd_rpc}
    handler = handlers.get(args.verb)
    if handler is None:
        print("not implemented yet: %s" % args.verb, file=sys.stderr)
        return EXIT_USAGE

    # One place where every outcome becomes an exit code, so no caller can
    # collapse ambiguous into error by forgetting to handle it.
    try:
        return handler(args)
    except Rejected as e:
        print("refused: %s" % e, file=sys.stderr)
        return EXIT_ERR
    except Ambiguous as e:
        print("AMBIGUOUS: %s — do not resend without checking" % e,
              file=sys.stderr)
        return EXIT_AMBIGUOUS
    except RpcError as e:
        print("herdr refused the write: %s" % e, file=sys.stderr)
        return EXIT_ERR
    except Fatal as e:
        print(e.msg, file=sys.stderr)
        return e.code


if __name__ == "__main__":
    sys.exit(main())
