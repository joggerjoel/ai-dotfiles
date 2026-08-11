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
import sys
import unicodedata

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


def build_parser():
    ap = argparse.ArgumentParser(
        prog="herdr-paste.py",
        description="Relay a credential into a herdr pane.")
    sub = ap.add_subparsers(dest="verb")
    sub.add_parser("list", help="panes you can paste into (read-only)")
    sub.add_parser("send", help="pick, paste, confirm, deliver")
    sub.add_parser("serve", help="the phone-friendly page; tailnet only")
    sub.add_parser("_validate", help=argparse.SUPPRESS)
    return ap


def main(argv=None):
    ap = build_parser()
    args = ap.parse_args(argv)

    if args.verb == "_validate":
        return cmd_validate(args)
    if args.verb is None:
        ap.print_usage(sys.stderr)
        return EXIT_USAGE

    print("not implemented yet: %s" % args.verb, file=sys.stderr)
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
