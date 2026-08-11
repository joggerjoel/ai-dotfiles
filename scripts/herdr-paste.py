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


def clean_label(s):
    """Make an untrusted label safe to print.

    Labels are tab titles and tmux session names, set by whatever runs inside
    the pane — remote ssh peers, CI output. They reach two hostile sinks: the
    operator's terminal, and the page holding the credential field.

    Strips C0/C1 controls AND every category-Cf format character. Controls
    alone are not enough: a bidi override (U+202E) or a zero-width joiner can
    visually reorder or forge a label at exactly the moment a human is asked to
    approve a credential delivery, which reopens the threat model at the
    display layer after closing it for matching.

    By codepoint, not byte — stripping raw 0x80..0x9F would mangle any
    multibyte character that happens to contain those bytes.
    """
    out = []
    for ch in s:
        o = ord(ch)
        if o < 0x20 or o == 0x7F or 0x80 <= o <= 0x9F:
            continue
        if unicodedata.category(ch) == "Cf":
            continue
        out.append(ch)
    return "".join(out)


def _herdr_json(*args):
    out = subprocess.run(["herdr"] + list(args),
                         capture_output=True, text=True).stdout
    return json.loads(out)["result"]


def list_panes():
    """Join workspaces, tabs and panes into one addressable list.

    Every label is sanitised on the way out, so no caller can forget to. The
    ids are daemon-assigned and pass through untouched: they are the identity,
    and the label is display only.
    """
    ws = {w["workspace_id"]: w.get("label", "?")
          for w in _herdr_json("workspace", "list")["workspaces"]}
    tabs = {t["tab_id"]: t for t in _herdr_json("tab", "list")["tabs"]}

    rows = []
    for i, p in enumerate(_herdr_json("pane", "list")["panes"], 1):
        tab = tabs.get(p.get("tab_id"), {})
        rows.append({
            "n": i,
            "workspace": clean_label(ws.get(p.get("workspace_id"), "?")),
            "tab_id": p.get("tab_id"),
            "pane_id": p["pane_id"],
            "label": clean_label(tab.get("label", "?")),
        })
    return rows


def cmd_list(args):
    preflight()
    protocol_check()
    rows = list_panes()
    if args.json:
        # The producer for --expect-tab: a scripted caller needs tab_id, and
        # the human-readable form leaves it out as noise.
        print(json.dumps(rows, indent=2))
        return EXIT_OK
    for r in rows:
        print("%3d  %-14s / %-24s %s"
              % (r["n"], r["workspace"], r["label"], r["pane_id"]))
    return EXIT_OK


def send_input(identity, value, timeout=5.0):
    """Deliver a value to a pane. The whole guarded tail, in one place.

    `identity` is the (tab_id, pane_id) pair captured when the target was
    chosen. Everything here runs after the human has answered, because
    confirmation waits on a human and the world moves while it waits.

    The re-verify lives here rather than in each front-end because it is the
    check most worth not duplicating — and the pair, not a bare pane id,
    because a recycled id IS present in a fresh listing, attached to a
    different pane. Checking presence alone would wave through exactly the
    delivery this is meant to stop.

    It narrows the window rather than closing it: the wire call carries only
    pane_id, and the socket API has no compare-and-send, so a recycle between
    this check and the write still lands in the wrong pane. What goes away is
    the human-scale window — the minutes spent authenticating in a browser.
    """
    tab_id, pane_id = identity
    validate(value)       # re-assert: the write is unreachable unvalidated
    protocol_check()      # re-check: a daemon may have restarted while we waited

    for row in list_panes():
        if row["pane_id"] == pane_id:
            if row["tab_id"] != tab_id:
                raise Fatal(EXIT_MISMATCH,
                            "pane %s now belongs to tab %s, not %s — refusing "
                            "to deliver" % (pane_id, row["tab_id"], tab_id))
            break
    else:
        raise Fatal(EXIT_MISMATCH,
                    "pane %s is no longer present — refusing to deliver" % pane_id)

    rpc("pane.send_input",
        {"pane_id": pane_id, "text": value, "keys": ["enter"]}, timeout=timeout)


def read_value(use_stdin):
    """Get the credential without letting it touch the screen or history.

    getpass reads from the controlling TTY without echo and without trimming;
    piping requires --stdin so the non-interactive path is a deliberate choice
    rather than the obvious one.
    """
    if use_stdin:
        return sys.stdin.read()
    import getpass
    return getpass.getpass("paste the value (input hidden): ")


def cmd_send(args):
    preflight()
    protocol_check()

    if args.pane or args.expect_tab:
        if not (args.pane and args.expect_tab):
            raise Fatal(EXIT_USAGE,
                        "--pane requires --expect-tab: a bare pane id can only "
                        "support a presence check, which a recycled id passes")
        identity = (args.expect_tab, args.pane)
        label = None
    else:
        rows = list_panes()
        if not rows:
            raise Fatal(EXIT_ERR, "no panes to paste into")
        for r in rows:
            print("%3d  %-14s / %-24s %s"
                  % (r["n"], r["workspace"], r["label"], r["pane_id"]))
        try:
            pick = int(input("target: "))
        except (ValueError, EOFError):
            raise Fatal(EXIT_USAGE, "not a number")
        chosen = next((r for r in rows if r["n"] == pick), None)
        if chosen is None:
            raise Fatal(EXIT_USAGE, "no such entry")
        identity = (chosen["tab_id"], chosen["pane_id"])
        label = chosen["label"]

    value = read_value(args.stdin)
    validate(value)

    if not args.yes:
        # The pane_id is printed beside the label deliberately: the label is
        # attacker-controlled, and homoglyphs survive sanitisation. The
        # daemon-assigned id is the part no pane can rewrite.
        print("deliver to %s  (%s)" % (label or identity[1], identity[1]))
        if input("confirm [y/N]: ").strip().lower() != "y":
            print("cancelled; nothing was sent", file=sys.stderr)
            return EXIT_ERR

    send_input(identity, value)
    print("delivered to %s" % identity[1])
    return EXIT_OK


DEFAULT_PORT = 8778


def resolve_bind_address():
    """Find the one address to bind, or refuse to start.

    An HTTP server binds an address, not a named interface. The tailnet address
    is what makes this page unreachable from the LAN and the internet, so if it
    cannot be established the answer is to stop — not to fall back, because the
    fallback is 0.0.0.0 and that would silently publish a terminal-injection
    endpoint to every network this machine is on.

    Exactly one address, too: two means the answer is ambiguous, and guessing
    which tailnet a credential page should live on is not a guess worth making.
    """
    try:
        r = subprocess.run(["tailscale", "ip", "-4"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as e:
        raise Fatal(EXIT_PREFLIGHT, "could not run tailscale: %s" % e)
    if r.returncode != 0:
        raise Fatal(EXIT_PREFLIGHT,
                    "tailscale could not report an address; refusing to start "
                    "rather than fall back to 0.0.0.0")
    addrs = [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
    if len(addrs) != 1:
        raise Fatal(EXIT_PREFLIGHT,
                    "tailscale reported %d addresses; expected exactly one"
                    % len(addrs))
    return addrs[0]


def build_handler(capability, bind_host, port, state):
    """The request handler, closed over this run's capability and address."""
    import html
    from http.server import BaseHTTPRequestHandler

    expected_host = "%s:%d" % (bind_host, port)

    class Handler(BaseHTTPRequestHandler):
        server_version = "herdr-paste"

        def log_message(self, fmt, *a):
            """Suppressed deliberately.

            The default logs the full request line to stderr, and the request
            line contains the capability path — a bearer secret. Leaving this
            on would defeat the rule that the capability never reaches anything
            persistent.
            """

        def _deny(self, code, why):
            body = ("refused: %s" % html.escape(why)).encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _authorized(self, method):
            # Host first: a mismatch means DNS rebinding or a proxy, and the
            # capability should not even be compared under those conditions.
            if self.headers.get("Host") != expected_host:
                self._deny(403, "unexpected Host header")
                return False
            if self.path.lstrip("/").split("?")[0] != capability:
                self._deny(404, "no such path")
                return False
            if method == "POST":
                origin = self.headers.get("Origin")
                if not origin or origin != "http://" + expected_host:
                    # Absent is refused too: a same-origin form post carries
                    # one. Some mobile browsers strip it, so say which header.
                    self._deny(403, "missing or foreign Origin header")
                    return False
            return True

        def do_GET(self):
            if not self._authorized("GET"):
                return
            body = state["render"]().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if not self._authorized("POST"):
                return
            self._deny(501, "not implemented yet")

    return Handler


def cmd_serve(args):
    import secrets
    from http.server import HTTPServer

    preflight()
    protocol_check()

    host = resolve_bind_address()
    port = args.port
    capability = secrets.token_urlsafe(32)

    state = {"render": lambda: "<!doctype html><title>herdr-paste</title>"
                               "<p>pane picker goes here</p>"}

    try:
        httpd = HTTPServer((host, port), build_handler(capability, host, port, state))
    except OSError as e:
        raise Fatal(EXIT_PREFLIGHT,
                    "cannot bind %s:%d (%s). Not falling back to another port: "
                    "the port is what an ACL names." % (host, port, e))

    url = "http://%s:%d/%s" % (host, port, capability)
    print(url)
    print("open this on a device joined to this tailnet; the page is not "
          "reachable from anywhere else")
    sys.stdout.flush()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
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
    p_list = sub.add_parser("list", help="panes you can paste into (read-only)")
    p_list.add_argument("--json", action="store_true",
                        help="full records including tab_id, for scripted callers")
    p_send = sub.add_parser("send", help="pick, paste, confirm, deliver")
    p_send.add_argument("--pane", help="target pane id (requires --expect-tab)")
    p_send.add_argument("--expect-tab", dest="expect_tab",
                        help="tab_id the pane must still belong to")
    p_send.add_argument("--stdin", action="store_true",
                        help="read the value from stdin instead of the TTY")
    p_send.add_argument("--yes", action="store_true",
                        help="skip the confirmation prompt (scripted use)")
    p_serve = sub.add_parser("serve", help="the phone-friendly page; tailnet only")
    p_serve.add_argument("--port", type=int, default=DEFAULT_PORT)
    p_serve.add_argument("--timeout", type=float, default=600.0,
                         help="seconds before the page shuts itself down")
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

    handlers = {"_validate": cmd_validate, "_rpc": cmd_rpc,
                "list": cmd_list, "send": cmd_send, "serve": cmd_serve}
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
