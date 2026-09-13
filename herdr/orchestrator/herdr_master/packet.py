"""
Task packet assembly (plan 10.2; skills/amnesiac-workers).

A packet is what one worker is given and the whole of what it is given. It is rebuilt
from scratch every attempt rather than mutated, because mutating the previous packet
reintroduces accumulation through the back door.

The three things a packet must never carry are the prior worker's transcript, any
summary of it, and the completion sentinel paired with a nonce. The first two have no
code path into this module by construction: nothing here accepts a transcript. The third
is checked, because a caller writing the instruction by hand could produce it.
"""

import importlib.util
import json
import pathlib
import re

import herdr

# The validator is the amnesiac-workers skill's, not a copy. Two implementations of
# "what may survive an attempt" would drift, and the drift would be invisible.
VALIDATOR = (
    pathlib.Path(__file__).resolve().parents[3]
    / "skills" / "amnesiac-workers" / "scripts" / "validate_state.py"
)

BLOCKER_INSTRUCTION = """\
If the goal is UNREACHABLE (the spec contradicts itself, a test cannot be satisfied
alongside another, or something outside this repo is missing), do NOT keep trying.
Write .herdr/blockers.json:

{"schema":1,"blockers":[{"need":"<what is missing, as an observation>",
 "blocks":"<which item this stops>","observed_via":"<command you ran>",
 "exit_code":<n>,"excerpt":"<literal output>","observed_at":"<ISO8601>"}]}

If you learn something durable and non-obvious from the repo, write .herdr/facts.json
with the same fields but "claim" in place of "need" and "blocks". Record only what a
command printed, never what you think it means: a record with no command and no output
behind it will be rejected and dropped."""


class PacketError(ValueError):
    pass


def _validator():
    spec = importlib.util.spec_from_file_location("validate_state", VALIDATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_validated(path, kind):
    """Load worker-authored records, dropping the file whole if it fails validation.

    The worker wrote these and the worker just failed, so they are untrusted input. A
    file that fails is dropped entire and its reasons returned for escalation; salvaging
    half a contaminated ledger is the judgment call the closed schema exists to remove.
    """
    path = pathlib.Path(path)
    if not path.exists():
        return [], []
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return [], [f"{path.name} is not valid JSON: {exc}"]
    try:
        problems = _validator().validate(doc)
    except Exception as exc:
        return [], [f"{path.name}: {exc}"]
    if problems:
        return [], [f"{path.name}: {p}" for p in problems]
    return doc.get(kind, []), []


def _section(title, body):
    return f"## {title}\n{body.strip()}\n" if str(body).strip() else ""


def build(*, goal, remaining, tree, nonce, instructions=(), verification=None,
          facts=(), blockers=(), scope=None):
    """Assemble one packet.

    `verification` is the previous attempt's result verbatim, or None on a first attempt.
    `facts` and `blockers` must already have passed load_validated; this function trusts
    its inputs and guards only the invariant a caller could break by hand.
    """
    if not goal or not str(goal).strip():
        raise PacketError("a packet with no goal cannot be dispatched")

    parts = [
        _section("Goal", str(goal)),
        _section("Remaining work", "\n".join(f"- {item}" for item in remaining) or "none listed"),
        _section("Where you are", f"{tree}\n" + (f"Scope: {scope}" if scope else "")),
    ]
    for name, text in instructions:
        parts.append(_section(f"Repo instructions ({name})", text))

    if verification:
        parts.append(_section(
            "Last verifier failure",
            f"$ {verification['command']}\nexit {verification['exit_code']}\n\n"
            f"{verification['excerpt']}",
        ))
    else:
        parts.append(_section("Last verifier failure", "none; this is the first attempt"))

    if facts:
        parts.append(_section("Established facts", "\n".join(
            f"- {f['claim']}  (via `{f['observed_via']}`: {f['excerpt'][:120]})" for f in facts)))
    if blockers:
        parts.append(_section("Known blockers", "\n".join(
            f"- {b['need']}  (blocks: {b['blocks']})" for b in blockers)))

    parts.append(_section("If you cannot finish", BLOCKER_INSTRUCTION))
    parts.append(_section(
        "Signalling completion",
        "Use the completion sentinel named in the machine context, followed by a space "
        f"and this nonce: {nonce}\nPrint nothing after it.",
    ))

    text = "\n".join(p for p in parts if p)

    # Symmetric pair of checks. The worker must be able to learn the literal, which it can
    # only do from the machine context carried in `instructions`; and the literal must never
    # appear next to a nonce, which is what the supervisor matches on. A packet that names
    # neither leaves the worker unable to signal completion at all, which reads at runtime
    # as a worker that finished silently.
    if herdr.DONE_SENTINEL not in text:
        raise PacketError(
            f"no instruction source names {herdr.DONE_SENTINEL}, so the worker cannot learn "
            "how to signal completion. Include the machine context in `instructions`."
        )
    if herdr.MATCHABLE.search(text):
        raise PacketError(
            "packet pairs the sentinel with a nonce; its own echo could satisfy the "
            "supervisor's match (2.3). Name the sentinel and the nonce separately."
        )
    if re.search(r"(?i)\b(previous|prior|earlier)\s+(agent|attempt|worker)\b", text):
        raise PacketError(
            "packet refers to a previous attempt; 10.2 forbids carrying its reasoning forward"
        )
    return text
