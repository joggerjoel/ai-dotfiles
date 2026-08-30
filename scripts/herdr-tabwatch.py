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
    """Names that mean *this* machine, which must never be ssh'd into.

    Lowercased and reduced to short forms, because none of the sources agree on
    case or domain: `hostname` says JoggerJoels-Mac-Studio.local, ssh config
    says joggerjoels-mac-studio.
    """
    names = set()
    full = socket.gethostname()
    for n in (full, full.split(".")[0]):
        names.add(n)
    for cmd in (["scutil", "--get", "LocalHostName"], ["hostname", "-s"]):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True,
                                 timeout=5).stdout.strip()
            if out:
                names.add(out)
        except (OSError, subprocess.SubprocessError):
            pass
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


def is_this_machine(label, locals_):
    """Would ssh'ing to `label` land us back where we started?

    Comparing the label to the hostname is not enough, and assuming otherwise
    is how the node ends up ssh'ing into itself. The workspace is called
    `macstudio` because that is its **ssh alias**; the box answers to
    `JoggerJoels-Mac-Studio`, and `Host macstudio` is in its own ssh config.
    The two names never match as strings.

    So ask ssh what the alias resolves to and compare *that*. The label check
    stays first for the ordinary case where a workspace is named after the
    hostname outright.
    """
    if label.split(".")[0].lower() in locals_:
        return True
    target = resolved_host(label)
    return bool(target and target.split(".")[0].lower() in locals_)


def workspace_labels():
    """workspace_id -> label. Re-read per event; workspaces get renamed."""
    res = rpc("workspace.list", {}) or {}
    return {w["workspace_id"]: w.get("label", "")
            for w in res.get("workspaces", [])}


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


def handle_tab(tab, hosts, locals_):
    """Decide about one new tab and act, or explain why not."""
    tab_id = tab.get("tab_id")
    label = workspace_labels().get(tab.get("workspace_id"), "")

    if not label:
        return "%s: workspace has no label" % tab_id
    if label not in hosts:
        return "%s: '%s' is not an ssh host" % (tab_id, label)
    # After the allowlist, not before: resolving costs an ssh -G, and a label
    # that is not a host we may dial never needs resolving at all.
    if is_this_machine(label, locals_):
        return "%s: workspace '%s' is this machine" % (tab_id, label)

    pane_id = pane_of_tab(tab_id)
    if not pane_id:
        return "%s: no single fresh pane" % tab_id

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
    log("subscribed%s (%d ssh hosts, self=%s)"
        % (" [DRY RUN — nothing will be typed]" if DRY_RUN else "",
           len(hosts), ",".join(locals_)))

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
            log(handle_tab(tab, hosts, locals_))
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
