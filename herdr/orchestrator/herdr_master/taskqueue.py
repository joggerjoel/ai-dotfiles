"""
The supervisor-owned task queue (plan 2.5).

The queue is a markdown file the supervisor both reads and rewrites, so parsing is
lossless: anything that is not a recognised queue line is prose and is preserved
verbatim on write. Identity lives in the line itself, as an HTML comment, so
inserting a line mid-run cannot remap a branch to a different task.
"""

import dataclasses
import enum
import re

LINE = re.compile(r"^- \[(?P<mark>[ x!>])\] (?P<title>.+)$")
ID_TAG = re.compile(r"\s*<!--\s*id:(?P<id>[a-z0-9][a-z0-9-]{0,46})\s*-->\s*$")
ALLOW_TEST_CHANGES = re.compile(r"^\s+allow-test-changes:\s*(?P<reason>.+?)\s*$")

# 2.5 says a line matching `^- \[` with an unknown mark escalates. Taken literally that
# flags an ordinary markdown link bullet, `- [text](url)`, as a corrupt queue line. The
# detector therefore requires exactly one character between the brackets.
MALFORMED = re.compile(r"^- \[[^\]]?\] ")


class Mark(str, enum.Enum):
    PENDING = " "
    IN_PROGRESS = ">"
    DONE = "x"
    QUARANTINED = "!"


# Only these transitions are legal. A queue that can go from DONE back to PENDING
# would re-dispatch verified work, and one that can skip PENDING -> DONE would mark
# a task complete without a verifier ever running (plan 6).
TRANSITIONS = {
    Mark.PENDING: {Mark.IN_PROGRESS, Mark.QUARANTINED},
    Mark.IN_PROGRESS: {Mark.DONE, Mark.QUARANTINED, Mark.PENDING},
    Mark.DONE: set(),
    Mark.QUARANTINED: {Mark.PENDING},
}


class UnknownMark(ValueError):
    """A `- [` line whose mark is not recognised. 2.5 escalates rather than guessing."""


class IllegalTransition(ValueError):
    pass


@dataclasses.dataclass
class Task:
    mark: Mark
    title: str
    task_id: str | None = None
    continuations: list = dataclasses.field(default_factory=list)
    index: int = -1

    @property
    def allow_test_changes(self):
        """Authorisation to modify existing tests, which the 6 test-surface gate otherwise suspends."""
        for line in self.continuations:
            hit = ALLOW_TEST_CHANGES.match(line)
            if hit:
                return hit.group("reason")
        return None

    def render(self):
        tag = f" <!-- id:{self.task_id} -->" if self.task_id else ""
        return [f"- [{self.mark.value}] {self.title}{tag}", *self.continuations]


@dataclasses.dataclass
class Queue:
    """Parsed queue. `body` holds every line; `tasks` indexes into it."""

    body: list
    tasks: list

    @property
    def pending(self):
        return [t for t in self.tasks if t.mark is Mark.PENDING]

    @property
    def in_progress(self):
        return [t for t in self.tasks if t.mark is Mark.IN_PROGRESS]

    @property
    def quarantined(self):
        return [t for t in self.tasks if t.mark is Mark.QUARANTINED]

    def status(self):
        """`done` when nothing is pending or in progress. Quarantined lines do not block it (2.5)."""
        if not self.tasks:
            return "no-work"
        if self.in_progress:
            return "in-progress"
        return "pending" if self.pending else "done"

    def next_dispatchable(self):
        """In-progress wins: a restart reconciles by task_id rather than re-dispatching (2.5)."""
        return (self.in_progress or self.pending or [None])[0]

    def by_id(self, task_id):
        return next((t for t in self.tasks if t.task_id == task_id), None)

    def set_mark(self, task, mark, task_id=None):
        if mark not in TRANSITIONS[task.mark]:
            raise IllegalTransition(f"{task.mark.name} -> {mark.name} for {task.title!r}")
        if mark is Mark.IN_PROGRESS and not (task_id or task.task_id):
            raise ValueError("in-progress requires a task_id; that mark is what makes restart safe")
        task.mark = mark
        if task_id:
            task.task_id = task_id
        # Length-preserving by construction: render() emits the line plus its own
        # continuations, so no other task's index moves.
        self.body[task.index : task.index + 1 + len(task.continuations)] = task.render()
        return task

    def render(self):
        return "\n".join(self.body) + "\n"


def parse(text):
    body = text.splitlines()
    tasks = []
    for n, line in enumerate(body):
        hit = LINE.match(line)
        if not hit:
            if MALFORMED.match(line):
                raise UnknownMark(f"line {n + 1}: {line!r}")
            if tasks and line.strip() and line[:1].isspace():
                tasks[-1].continuations.append(line)
            continue
        title = hit.group("title")
        tag = ID_TAG.search(title)
        tasks.append(
            Task(
                mark=Mark(hit.group("mark")),
                title=ID_TAG.sub("", title) if tag else title,
                task_id=tag.group("id") if tag else None,
                index=n,
            )
        )
    return Queue(body=body, tasks=tasks)


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        return Queue(body=[], tasks=[])
    return parse(text)
