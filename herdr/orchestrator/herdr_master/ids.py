"""
Identity for work units (plan 2.4).

A task_id is interpolated into git refs, worktree paths, and pane names, so it is
constrained at mint time and re-asserted before every use. The charset is the
contract; callers never build one by hand.
"""

import re
import secrets

SLUG_MAX = 40
TASK_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,46}$")
INCIDENT_ID = re.compile(r"^[0-9a-f]{12}-[0-9]{8}-[0-9a-f]{6}$")

_NON_SLUG = re.compile(r"[^a-z0-9]+")


class UnsluggableTitle(ValueError):
    """A title with no alphanumerics cannot produce an id, and 2.4 escalates rather than inventing one."""


def slugify(title, max_len=SLUG_MAX):
    slug = _NON_SLUG.sub("-", title.lower()).strip("-")[:max_len].rstrip("-")
    if not slug:
        raise UnsluggableTitle(f"no alphanumeric characters in {title!r}")
    return slug


def mint_task_id(title, suffix=None):
    """Mint `<slug>-<6 hex>`. The suffix makes two identically-titled queue lines distinct."""
    task_id = f"{slugify(title)}-{suffix or secrets.token_hex(3)}"
    if not TASK_ID.match(task_id):
        raise UnsluggableTitle(f"minted id {task_id!r} fails the charset assertion")
    return task_id


def assert_task_id(task_id):
    """Re-assert before interpolation. A failure here is a bug, not input to sanitize (plan 8)."""
    if not isinstance(task_id, str) or not TASK_ID.match(task_id):
        raise ValueError(f"unsafe task_id {task_id!r}; refusing to interpolate")
    return task_id


def assert_incident_id(incident_id):
    if not isinstance(incident_id, str) or not INCIDENT_ID.match(incident_id):
        raise ValueError(f"unsafe incident_id {incident_id!r}; refusing to interpolate")
    return incident_id
