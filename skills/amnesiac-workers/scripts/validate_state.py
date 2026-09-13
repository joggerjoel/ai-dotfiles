#!/usr/bin/env python3
"""
validate_state.py - Boundary validator for amnesiac-worker state files.

Three file kinds, discriminated by their sole top-level collection key:

    state.json     {"schema": 1, "unit_id": ..., "attempt": ...}   master-owned
    facts.json     {"schema": 1, "facts": [...]}                   worker-authored
    blockers.json  {"schema": 1, "blockers": [...]}                worker-authored

The worker-authored kinds are untrusted input. Every record must carry the
command that produced it and a literal excerpt of that command's output, which
is what makes a belief unwritable: no command emits "I think the auth
architecture is wrong". The lexeme ban below is a backstop, not the mechanism.

Exit 0 valid, 1 invalid (reasons on stdout), 2 usage error.
"""

import argparse
import json
import re
import sys
from datetime import datetime

SCHEMA_VERSION = 1

# A fact is one atomic observation, so 200 is generous. A blocker has to name the
# conflicting parties and what each produced, which a live run measured at 276 chars
# for a two-test contradiction; 200 rejected a correct record.
MAX_PROSE_CHARS = {"claim": 200, "need": 400, "blocks": 200}
MAX_EXCERPT_CHARS = 2000
MAX_RECORDS = 50

EVIDENCE_FIELDS = {
    "observed_via": str,
    "exit_code": int,
    "excerpt": str,
    "observed_at": str,
}

FACT_FIELDS = {"claim": str, **EVIDENCE_FIELDS}
BLOCKER_FIELDS = {"need": str, "blocks": str, **EVIDENCE_FIELDS}

STATE_FIELDS = {
    "schema": int,
    "unit_id": str,
    "attempt": int,
    "retry_budget": int,
    "verification": (dict, type(None)),
}
VERIFICATION_FIELDS = {"command": str, "exit_code": int, "excerpt": str}

# Reasoning markers. A record whose prose field trips one of these is carrying a
# belief forward, which is the whole thing this file exists to stop.
BANNED = [
    (r"\bi (?:think|believe|suspect|assume|feel|reckon)\b", "first-person belief"),
    (r"\b(?:probably|maybe|perhaps|likely|presumably|apparently)\b", "hedge"),
    (r"\bseems?\b|\bappears? to\b", "hedge"),
    (r"\bmight\b|\bshould\b|\bcould be\b", "speculation"),
    (r"\bwe (?:should|could|need to|ought)\b", "recommendation"),
    (r"\b(?:recommend|recommends|suggest|suggests|propose|proposes)\b", "recommendation"),
    (r"\b(?:previous|prior|earlier) (?:agent|attempt|worker)\b", "cross-attempt carryover"),
    (r"\bmy (?:guess|opinion|hunch|read)\b|\bin my opinion\b", "opinion"),
    (r"\b(?:caused by|because of|due to)\b", "speculative causation"),
    (r"\b(?:architecture|design|approach) is\b", "design judgment"),
]
BANNED = [(re.compile(p, re.IGNORECASE), label) for p, label in BANNED]


class Invalid(Exception):
    pass


def _iso8601(value, where, errors):
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        errors.append(f"{where}.observed_at is not ISO-8601: {value!r}")


def _prose(value, where, field, errors):
    if not value.strip():
        errors.append(f"{where}.{field} is empty")
        return
    limit = MAX_PROSE_CHARS[field]
    if len(value) > limit:
        errors.append(
            f"{where}.{field} is {len(value)} chars, limit {limit}. "
            "State one observation, not a narrative"
        )
    for pattern, label in BANNED:
        hit = pattern.search(value)
        if hit:
            errors.append(
                f"{where}.{field} contains {label} ({hit.group(0)!r}). "
                "Record what a command printed, not what it means"
            )


def _record(record, spec, index, kind, errors):
    where = f"{kind}[{index}]"
    if not isinstance(record, dict):
        errors.append(f"{where} is {type(record).__name__}, expected object")
        return

    missing = sorted(set(spec) - set(record))
    extra = sorted(set(record) - set(spec))
    if missing:
        errors.append(f"{where} missing required field(s): {', '.join(missing)}")
    if extra:
        errors.append(
            f"{where} has unpermitted field(s): {', '.join(extra)}. "
            "The schema is closed so reasoning cannot be smuggled in beside the evidence"
        )

    for field, expected in spec.items():
        if field not in record:
            continue
        value = record[field]
        if expected is int and isinstance(value, bool):
            errors.append(f"{where}.{field} is bool, expected int")
            continue
        if not isinstance(value, expected):
            errors.append(
                f"{where}.{field} is {type(value).__name__}, expected {expected.__name__}"
            )
            continue
        if field in ("claim", "need", "blocks"):
            _prose(value, where, field, errors)
        elif field == "observed_via" and not value.strip():
            errors.append(
                f"{where}.observed_via is empty. Every record names the command that produced it"
            )
        elif field == "excerpt":
            if not value.strip():
                errors.append(
                    f"{where}.excerpt is empty. A claim with no output behind it is a belief"
                )
            elif len(value) > MAX_EXCERPT_CHARS:
                errors.append(
                    f"{where}.excerpt is {len(value)} chars, limit {MAX_EXCERPT_CHARS}"
                )
        elif field == "observed_at":
            _iso8601(value, where, errors)


def _collection(doc, key, spec, errors):
    records = doc[key]
    if not isinstance(records, list):
        errors.append(f"{key} is {type(records).__name__}, expected array")
        return
    if len(records) > MAX_RECORDS:
        errors.append(
            f"{key} holds {len(records)} records, limit {MAX_RECORDS}. "
            "An unbounded ledger is a transcript by another name"
        )
    for index, record in enumerate(records):
        _record(record, spec, index, key, errors)


def _state(doc, errors):
    missing = sorted(set(STATE_FIELDS) - set(doc))
    extra = sorted(set(doc) - set(STATE_FIELDS))
    if missing:
        errors.append(f"state missing required field(s): {', '.join(missing)}")
    if extra:
        errors.append(
            f"state has unpermitted field(s): {', '.join(extra)}. "
            "Files changed, commit, and remaining TODO derive from git and the queue, "
            "so storing them here would let them drift"
        )

    for field, expected in STATE_FIELDS.items():
        if field not in doc:
            continue
        value = doc[field]
        if expected is int and isinstance(value, bool):
            errors.append(f"state.{field} is bool, expected int")
            continue
        if not isinstance(value, expected):
            name = expected.__name__ if isinstance(expected, type) else "object or null"
            errors.append(f"state.{field} is {type(value).__name__}, expected {name}")

    if isinstance(doc.get("attempt"), int) and doc["attempt"] < 1:
        errors.append("state.attempt is below 1; attempts are one-indexed")
    if isinstance(doc.get("retry_budget"), int) and doc["retry_budget"] < 0:
        errors.append("state.retry_budget is negative")

    verification = doc.get("verification")
    if isinstance(verification, dict):
        missing = sorted(set(VERIFICATION_FIELDS) - set(verification))
        extra = sorted(set(verification) - set(VERIFICATION_FIELDS))
        if missing:
            errors.append(f"state.verification missing: {', '.join(missing)}")
        if extra:
            errors.append(f"state.verification has unpermitted field(s): {', '.join(extra)}")
        for field, expected in VERIFICATION_FIELDS.items():
            value = verification.get(field)
            if field in verification and not isinstance(value, expected):
                errors.append(
                    f"state.verification.{field} is {type(value).__name__}, "
                    f"expected {expected.__name__}"
                )


DISCRIMINATORS = {
    "facts": lambda doc, errors: _collection(doc, "facts", FACT_FIELDS, errors),
    "blockers": lambda doc, errors: _collection(doc, "blockers", BLOCKER_FIELDS, errors),
    "unit_id": lambda doc, errors: _state(doc, errors),
}


def validate(doc):
    errors = []
    if not isinstance(doc, dict):
        raise Invalid(f"top level is {type(doc).__name__}, expected object")

    if doc.get("schema") != SCHEMA_VERSION:
        errors.append(f"schema is {doc.get('schema')!r}, expected {SCHEMA_VERSION}")

    present = [key for key in DISCRIMINATORS if key in doc]
    if len(present) != 1:
        raise Invalid(
            "expected exactly one of facts, blockers, unit_id at the top level, "
            f"found {present or 'none'}"
        )

    DISCRIMINATORS[present[0]](doc, errors)
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument("path", help="state.json, facts.json, or blockers.json")
    args = parser.parse_args(argv)

    try:
        with open(args.path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except OSError as exc:
        print(f"cannot read {args.path}: {exc}")
        return 2
    except json.JSONDecodeError as exc:
        print(f"{args.path} is not valid JSON: {exc}")
        return 1

    try:
        errors = validate(doc)
    except Invalid as exc:
        print(f"{args.path}: {exc}")
        return 1

    if errors:
        print(f"{args.path}: {len(errors)} problem(s)")
        for error in errors:
            print(f"  - {error}")
        return 1

    print(f"{args.path}: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
