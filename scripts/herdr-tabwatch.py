#!/usr/bin/env python3
"""herdr-tabwatch — connect each new tab to the host its workspace is named for.

Subscribes to `tab.created` and, when the new tab's workspace is labelled with a
host this machine already knows how to reach, types an ssh command into the
tab's pane so it lands on that box and says which one it is.

Runs on the NODE, beside the API server it subscribes to. The laptop only holds
a bridge socket and no API (see references/herdr-paste.md, "Finding the
socket"), and a watcher there would also die every time the lid closed —
missing exactly the tabs opened while it was asleep.

It only ever types into panes. It creates nothing, closes nothing, and holds no
credential, which is why it can be a daemon at all.
"""
import json
import os
import socket
import subprocess
import sys
import time

# Typing into someone's live terminal is not a thing to switch on blind, so
# every decision can be watched first: --dry-run reports exactly what it would
# have typed and sends nothing.
DRY_RUN = "--dry-run" in sys.argv

SOCKET_PATH = os.environ.get(
    "HERDR_SOCKET_PATH", os.path.expanduser("~/.config/herdr/herdr.sock"))

# How long to let a fresh ssh settle before deciding it failed. Generous: a
# cold tailnet connection to a sleeping box is slow, and the cost of waiting
# is nothing while the cost of giving up early is a half-typed command.
SSH_SETTLE_MS = 20000

# On the SIP-sealed system volume at a fixed path, on every Mac. Not looked up
# through PATH: a probe that cannot run does not raise, it returns one name
# fewer, and an alias pointing at that name stops looking like ourselves.
SCUTIL = "/usr/sbin/scutil"

# LocalHostName is a macOS concept and scutil ships only there. Elsewhere
# gethostname(3) is the whole of this machine's identity, so identity is
# complete without asking, and demanding an answer would refuse every tab on a
# Linux node rather than protect it.
IS_DARWIN = sys.platform == "darwin"

# Remembering handled tabs prevents a reconnect from re-typing into panes that
# were already connected. Bounded because this process is meant to run for
# weeks.
SEEN_CAP = 512


def rpc(method, params, timeout=10.0, sock=None):
    """One request, one reply. Opens its own connection unless given one."""
    own = sock is None
    if own:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(SOCKET_PATH)
    try:
        req = json.dumps({"id": "tabwatch", "method": method, "params": params})
        sock.sendall(req.encode() + b"\n")
        line = sock.makefile("rb").readline()
        if not line:
            return None
        return json.loads(line).get("result")
    finally:
        if own:
            sock.close()


def ssh_hosts():
    """Literal `Host` aliases from ssh config — the set of names we may dial.

    An allowlist, deliberately, rather than asking DNS whether a label
    resolves. A workspace can be called anything; "it resolved" is not the same
    as "the operator meant it as a machine", and the failure mode of guessing
    wrong is an unasked-for ssh session in someone's terminal.

    Wildcards are dropped. `*-jump` is a pattern for configuring other hosts,
    not a host, and treating it as one would let a label like `foo-jump` dial
    something that does not exist.
    """
    path = os.path.expanduser("~/.ssh/config")
    hosts = set()
    try:
        with open(path) as fh:
            for line in fh:
                if line.strip().lower().startswith("host "):
                    for alias in line.split(None, 1)[1].split():
                        if not any(c in alias for c in "*?!"):
                            hosts.add(alias)
    except OSError:
        pass
    return hosts


def local_names():
    """Names that mean *this* machine, or None when we could not find out.

    None rather than a short set, because a short set is indistinguishable from
    a correct one at the call site and every caller then treats "I could not
    tell" as "not us". That is the whole of the original incident. The probe
    could not run, the set came back one name shorter, nothing raised, and the
    node dialled itself.

    Lowercased and reduced to short forms, because none of the sources agree on
    case or domain: `hostname` says JoggerJoels-Mac-Studio.local, ssh config
    says joggerjoels-mac-studio.
    """
    names = set()
    full = socket.gethostname()
    for n in (full, full.split(".")[0]):
        names.add(n)
    if not IS_DARWIN:
        return {n.split(".")[0].lower() for n in names if n}
    # `scutil` is the only source that knows LocalHostName, and LocalHostName is
    # what this fleet's ssh aliases resolve to, so it is the probe that decides
    # whether an alias is us. `hostname -s` is not consulted: it prints the
    # short form of gethostname(3), which the lines above already hold.
    #
    # Absolute so that the guard cannot be reopened by anything that writes an
    # environment, which the generated plists do. This was an env var for one
    # revision, so the suite could point it at a fixture, and that override then
    # ran in every test and left the real path exercised by none of them.
    try:
        out = subprocess.run([SCUTIL, "--get", "LocalHostName"],
                             capture_output=True, text=True,
                             timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError) as e:
        log("identity probe failed (%s: %s)" % (SCUTIL, e))
        return None
    if not out:
        log("identity probe returned nothing (%s)" % SCUTIL)
        return None
    names.add(out)
    return {n.split(".")[0].lower() for n in names if n}


def resolved_host(alias):
    """What `ssh <alias>` would really connect to, per ssh config."""
    try:
        out = subprocess.run(["ssh", "-G", alias], capture_output=True,
                             text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        if line.lower().startswith("hostname "):
            return line.split(None, 1)[1].strip()
    return None


def refusal_to_dial(label, locals_):
    """Why `label` must not be ssh'd into, or None when it is safe to dial.

    Four answers, not two. The identity set itself may be missing. The boolean this replaced folded "cannot tell" in
    with "safe to dial", so every way of failing to identify a machine ended in
    typing. That is the same shape as the bug above: a probe that cannot run
    weakens the guard instead of stopping it. `resolved_host` returns None when ssh cannot be
    run or does not answer, and that used to mean "elsewhere, go ahead". Note
    it is not the case for a name that does not resolve: `ssh -G` expands
    config without consulting DNS, so it prints `hostname <alias>` for a host
    that will never answer, and that reaches connect_pane by design.

    Comparing the label to the hostname is not enough, and assuming otherwise
    is how the node ends up ssh'ing into itself. The workspace is called
    `macstudio` because that is its **ssh alias**; the box answers to
    `JoggerJoels-Mac-Studio`, and `Host macstudio` is in its own ssh config.
    The two names never match as strings.

    So ask ssh what the alias resolves to and compare *that*. The label check
    stays first for the ordinary case where a workspace is named after the
    hostname outright.
    """
    if locals_ is None:
        return "identity of this machine is unknown, so not dialling '%s'" % label
    if label.split(".")[0].lower() in locals_:
        return "workspace '%s' is this machine" % label
    target = resolved_host(label)
    if target is None:
        return "cannot resolve '%s', so not assuming it is elsewhere" % label
    if target.split(".")[0].lower() in locals_:
        return "workspace '%s' is this machine, via %s" % (label, target)
    return None


def workspace_labels():
    """workspace_id -> label. Re-read per event; workspaces get renamed."""
    res = rpc("workspace.list", {}) or {}
    return {w["workspace_id"]: w.get("label", "")
            for w in res.get("workspaces", [])}


def existing_tab_ids():
    """Tab ids that already exist. Captured BEFORE subscribing, always.

    `events.subscribe` does not start a clean stream: it **replays historical
    `tab_created` events**, including for tabs closed long ago. A watcher that
    treats them as new types into every pre-existing single-pane tab the moment
    it connects — and under launchd's KeepAlive, again on every restart.

    This was not theoretical. It typed an ssh command into a live pane running
    an agent session, because that pane's tab was replayed on subscribe. The
    tell had been visible in every dry run — the same tab ids appearing each
    time — and reads as "new tabs" only if you do not check whether they are.

    Snapshot first, then subscribe. The gap between the two can lose a tab
    created in that instant, which is the right direction to fail.
    """
    res = rpc("tab.list", {}) or {}
    return {t["tab_id"] for t in res.get("tabs", [])}


def pane_is_untouched(pane_id, max_lines=3):
    """Does this pane look like a shell nobody has used yet?

    Second guard, independent of the first. A freshly created tab's pane has a
    prompt and little else; a pane someone is working in has scrollback. Typing
    into the latter is the harm this whole program has to avoid, so when the
    pane has anything to say for itself, leave it alone.

    Deliberately conservative: unreadable means untouched=False, because the
    safe answer to "I cannot tell" is to do nothing.
    """
    res = rpc("pane.read", {"pane_id": pane_id, "source": "recent_unwrapped",
                            "lines": 40, "strip_ansi": True})
    if res is None:
        return False
    text = res.get("text") or res.get("output") or ""
    return len([ln for ln in text.splitlines() if ln.strip()]) <= max_lines


def pane_of_tab(tab_id):
    """The single pane of a freshly created tab, or None.

    A new tab has exactly one pane. If it somehow has several by the time we
    look, the tab is not fresh in the way this assumed and we leave it alone
    rather than pick one — typing a command into an arbitrary pane of someone's
    existing work is the worst outcome available here.
    """
    res = rpc("pane.list", {}) or {}
    panes = [p for p in res.get("panes", []) if p.get("tab_id") == tab_id]
    return panes[0]["pane_id"] if len(panes) == 1 else None


def ssh_command(host):
    """The one line typed into a new tab.

    One line, not two. The obvious shape — send `ssh host`, then send
    `hostname` — is a race: the second write lands whenever it lands, which may
    be before the remote shell exists, and the command is then eaten by ssh's
    own input or split across the handshake. Making the remote shell print it
    removes the timing question entirely.

    `exec "$SHELL" -l` keeps the tab interactive afterwards, which is the whole
    point of opening it; without it the pane would print a hostname and die.
    """
    return 'ssh -t %s \'hostname; exec "$SHELL" -l\'' % host


def connect_pane(pane_id, host):
    """Put the pane on `host`, with the hostname printed on arrival."""
    rpc("pane.send_input", {"pane_id": pane_id, "text": ssh_command(host),
                            "keys": ["enter"]})
    # Condition, not a sleep: wait for the host to actually say its name back.
    # A fixed sleep would be wrong in both directions on a fleet where one box
    # answers instantly and another is waking up.
    return rpc("pane.wait_for_output", {
        "pane_id": pane_id,
        "source": "recent_unwrapped",
        "match": {"type": "substring", "value": host},
        "timeout_ms": SSH_SETTLE_MS,
    })


def handle_tab(tab, hosts, locals_, preexisting):
    """Decide about one new tab and act, or explain why not."""
    tab_id = tab.get("tab_id")
    if tab_id in preexisting:
        return "%s: already existed before we subscribed (replay)" % tab_id
    label = workspace_labels().get(tab.get("workspace_id"), "")

    if not label:
        return "%s: workspace has no label" % tab_id
    if label not in hosts:
        return "%s: '%s' is not an ssh host" % (tab_id, label)
    # After the allowlist, not before: resolving costs an ssh -G, and a label
    # that is not a host we may dial never needs resolving at all.
    refusal = refusal_to_dial(label, locals_)
    if refusal:
        return "%s: %s" % (tab_id, refusal)

    pane_id = pane_of_tab(tab_id)
    if not pane_id:
        return "%s: no single fresh pane" % tab_id
    if not pane_is_untouched(pane_id):
        return "%s: %s already has output — not typing into it" % (tab_id,
                                                                   pane_id)

    if DRY_RUN:
        return "%s: WOULD type into %s: %s" % (tab_id, pane_id,
                                               ssh_command(label))
    ok = connect_pane(pane_id, label)
    return "%s: ssh %s into %s%s" % (tab_id, label, pane_id,
                                     "" if ok else " (no confirmation)")


def watch():
    """Subscribe and dispatch until the socket goes away."""
    hosts, locals_ = ssh_hosts(), local_names()
    seen = []
    # Before subscribing, never after: see existing_tab_ids().
    preexisting = existing_tab_ids()

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(None)          # events arrive whenever they arrive
    s.connect(SOCKET_PATH)
    s.sendall(json.dumps({"id": "sub", "method": "events.subscribe",
                          "params": {"subscriptions": [{"type": "tab.created"}]}
                          }).encode() + b"\n")
    f = s.makefile("rb")
    ack = f.readline()
    if not ack:
        raise OSError("socket closed before the subscription was acknowledged")
    log("subscribed%s (%d ssh hosts, %d pre-existing tabs ignored, self=%s)"
        % (" [DRY RUN — nothing will be typed]" if DRY_RUN else "",
           len(hosts), len(preexisting),
           ",".join(sorted(locals_)) if locals_ else "UNKNOWN, refusing every tab"))

    for line in f:
        try:
            frame = json.loads(line)
        except ValueError:
            continue
        if frame.get("event") != "tab_created":
            continue
        tab = frame.get("data", {}).get("tab", {})
        tab_id = tab.get("tab_id")
        if not tab_id or tab_id in seen:
            continue
        seen.append(tab_id)
        del seen[:-SEEN_CAP]
        try:
            log(handle_tab(tab, hosts, locals_, preexisting))
        except (OSError, ValueError) as e:
            log("%s: failed — %s" % (tab_id, e))
    raise OSError("event stream ended")


def log(msg):
    print("%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg), flush=True)


def main():
    """Reconnect forever. herdr restarts; this should not need to."""
    backoff = 1
    while True:
        try:
            watch()
            backoff = 1
        except (OSError, ValueError) as e:
            log("disconnected (%s); retrying in %ds" % (e, backoff))
        time.sleep(backoff)
        backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    sys.exit(main())
