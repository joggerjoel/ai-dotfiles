#!/usr/bin/env bash
# Tests for bin/global-todo. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# No network, no real `claude -p`, and no reads of the live claude-mem
# database. Every LLM response is a stub and every fixture is hand-authored --
# a fixture built from a slice of the real database would ship this user's
# session history to a public repo.
#
# The cases that matter most are the durability ones. An earlier revision
# derived each item's id from the LLM-authored item TEXT, so re-extraction
# reworded items, minted fresh ids, and resurrected work already marked done.
# Test 4 is that exact path: same observations, deliberately different wording.
# It must stay load-bearing -- an earlier version of it passed vacuously
# because the advanced watermark meant the second refresh selected zero rows
# and never exercised dedupe at all.
#
# Runs under bash 3.2 (stock macOS): no associative arrays, no mapfile.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# Exported: the python blocks below read DOT from the environment, so this
# must survive into subprocesses. Without the export the suite passes when run
# by hand and KeyErrors under run-all-tests.sh.
export DOT
DOT=$(cd "$HERE/.." && pwd)
GT="$DOT/bin/global-todo"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/globaltodo-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

py() { PYTHONPATH="$DOT/lib" python3 "$@"; }

# --- fixture docs tree -----------------------------------------------------
DOCS="$TMP/docs/superpowers/plans"
mkdir -p "$DOCS"

printf '**Status:** Built. shipped in v2\n\n- [ ] stale box\n' > "$DOCS/done.md"
printf '**Status:** approved, not yet implemented\n\n- [ ] a\n- [ ] b\n' > "$DOCS/live.md"
printf '**Status:** incomplete\n\n- [ ] still open\n' > "$DOCS/incomplete.md"
printf '**Status:** not yet complete\n\n- [ ] also open\n' > "$DOCS/notyet.md"
printf '# no status line here\n\n- [ ] must still emit\n' > "$DOCS/nostatus.md"

export GLOBAL_TODO_DOCS_ROOTS="$TMP/docs/superpowers"

run() { GLOBAL_TODO_DIR="$1" "$GT" "${@:2}" 2>&1; }
count() { # <store dir> <python expr over `items`>
  # eval() is deliberate and safe HERE only: every expression passed to this
  # helper is a string literal written in this file, never a value read from
  # the store, the environment, or a model response. It exists so assertions
  # read as one line instead of a heredoc each. Do not extend it to take
  # anything that crosses a trust boundary.
  py - "$1" "$2" <<'PY'
import json, sys
items = json.load(open(sys.argv[1] + "/global-todo.json"))["items"]
print(eval(sys.argv[2]))  # noqa: S307 - literal test expressions only
PY
}

# ===========================================================================
printf '\nDocs source\n'
# ===========================================================================
D1="$TMP/s1"
out=$(run "$D1" refresh --docs-only)

n=$(count "$D1" "len(items)")
[ "$n" = "4" ] && ok "terminal Status is skipped, everything else emits" \
                || ko "terminal Status is skipped, everything else emits" "got $n records, want 4"

# An unanchored /built|shipped|merged|complete/i matches "incomplete" and
# "not yet built" as substrings -- silently suppressing the most natural
# phrasings of "still open". This is the regression guard for that.
got=$(count "$D1" "sorted(i['path'].split('/')[-1] for i in items)")
case "$got" in
  *incomplete.md*) ok "'incomplete' is not swallowed by the status regex" ;;
  *) ko "'incomplete' is not swallowed by the status regex" "$got" ;;
esac
case "$got" in
  *notyet.md*) ok "'not yet complete' is not swallowed" ;;
  *) ko "'not yet complete' is not swallowed" "$got" ;;
esac
case "$got" in
  *nostatus.md*) ok "a file with no Status line still emits" ;;
  *) ko "a file with no Status line still emits" "$got" ;;
esac
case "$got" in
  *done.md*) ko "terminal Status file is excluded" "done.md present" ;;
  *) ok "terminal Status file is excluded" ;;
esac

steps=$(count "$D1" "[i['remaining_steps'] for i in items if i['path'].endswith('live.md')][0]")
[ "$steps" = "2" ] && ok "remaining_steps counts unchecked boxes" \
                   || ko "remaining_steps counts unchecked boxes" "got $steps, want 2"

# --- idempotency -----------------------------------------------------------
run "$D1" refresh --docs-only >/dev/null
n2=$(count "$D1" "len(items)")
[ "$n2" = "4" ] && ok "second consecutive refresh adds nothing" \
                || ko "second consecutive refresh adds nothing" "grew to $n2"

# --- rescan stability: tick a box, count updates, no duplicate -------------
printf '**Status:** approved, not yet implemented\n\n- [x] a\n- [ ] b\n' > "$DOCS/live.md"
run "$D1" refresh --docs-only >/dev/null
n3=$(count "$D1" "len(items)")
s3=$(count "$D1" "[i['remaining_steps'] for i in items if i['path'].endswith('live.md')][0]")
[ "$n3" = "4" ] && [ "$s3" = "1" ] \
  && ok "ticking a box updates the count without duplicating" \
  || ko "ticking a box updates the count without duplicating" "records=$n3 steps=$s3"

# --- auto-close when Status goes terminal ----------------------------------
printf '**Status:** Built.\n\n- [ ] leftover\n' > "$DOCS/live.md"
run "$D1" refresh --docs-only >/dev/null
st=$(count "$D1" "[i['status'] for i in items if i['path'].endswith('live.md')][0]")
[ "$st" = "done" ] && ok "docs record auto-closes when Status goes terminal" \
                   || ko "docs record auto-closes when Status goes terminal" "status=$st"

# ===========================================================================
printf '\nDurability\n'
# ===========================================================================
py - <<'PY'
import sys, os, tempfile
sys.path.insert(0, os.environ["DOT"] + "/lib")
d = tempfile.mkdtemp()
os.environ["GLOBAL_TODO_DIR"] = d
from pathlib import Path
import global_todo.core as core
core.STORE_DIR = Path(d)

fails = []
def check(name, cond):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}")
    if not cond: fails.append(name)

# Same observations, deliberately different wording. Under text-derived ids
# this minted a new id and resurrected the closed item.
a = core.Item(id=core.claude_mem_id([10, 11]), topic="p / t", project="p",
              text="Drain the sync outbox", source_ids=[10, 11])
a.status, a.closed_by = "done", "user"
reworded = core.Item(id=core.claude_mem_id([11, 10]), topic="p / t", project="p",
                     text="Flush the outbox table backlog", source_ids=[11, 10])
merged, added, _ = core.merge([a], [reworded])
check("provenance id survives a total rewording", added == 0 and merged[0].status == "done")
check("source_ids order does not change the id",
      core.claude_mem_id([11, 10]) == core.claude_mem_id([10, 11]))

# The assertion above passes through merge(), so it could in principle be
# rescued by the fuzzy backstop rather than by the id scheme. This one cannot:
# it pins the id function's inputs directly. If anyone reintroduces item text
# into the key, this fails immediately instead of waiting for a rewording that
# happens to score under the Jaccard threshold.
import inspect
check("claude_mem_id takes only source_ids",
      list(inspect.signature(core.claude_mem_id).parameters) == ["source_ids"])
check("the same observations always hash the same, regardless of wording",
      core.claude_mem_id([10, 11]) == core.claude_mem_id([10, 11]))
check("different observations hash differently",
      core.claude_mem_id([10, 11]) != core.claude_mem_id([10, 12]))

# The reworded pair used above scores 0.286 -- well under the 0.7 threshold --
# so the fuzzy pass genuinely cannot catch it. That is what makes the id
# scheme, not the backstop, the thing under test.
check("the reworded pair is below the fuzzy threshold",
      core.jaccard(core.normalize("Drain the sync outbox"),
                   core.normalize("Flush the outbox table backlog")) < 0.7)

# Fuzzy scoped to OPEN items only was how reworded near-duplicates of closed
# work got appended as new.
b = core.Item(id="aaaaaaaa", topic="p / t", project="p",
              text="fix the broken symlink in the vendor script")
b.status = "dismissed"
near = core.Item(id="bbbbbbbb", topic="p / t", project="p",
                 text="fix the broken symlink in the vendor script now")
m2, added2, _ = core.merge([b], [near])
check("fuzzy pass sees closed records", added2 == 0 and m2[0].status == "dismissed")
check("absorbed id becomes an alias", "bbbbbbbb" in m2[0].alias_ids)

# Distinct work in the same project must NOT be collapsed.
c = core.Item(id="cccccccc", topic="p / t", project="p", text="rotate the API credential")
far = core.Item(id="dddddddd", topic="p / t", project="p", text="paginate the results table")
_, added3, _ = core.merge([c], [far])
check("unrelated items are not merged", added3 == 1)

sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && pass=$((pass + 9)) || fail=$((fail + 1))

# ===========================================================================
printf '\nValidation and safety\n'
# ===========================================================================
py - <<'PY'
import sys, os, json, tempfile
sys.path.insert(0, os.environ["DOT"] + "/lib")
d = tempfile.mkdtemp(); os.environ["GLOBAL_TODO_DIR"] = d
from pathlib import Path
import global_todo.core as core
from global_todo import render
core.STORE_DIR = Path(d); core.STORE = Path(d) / "global-todo.json"
core.BAK = Path(d) / "global-todo.json.bak"; core.STATE = Path(d) / ".state.json"
core.LOG = Path(d) / ".log"; render.STORE_DIR = Path(d)

fails = []
def check(name, cond):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}")
    if not cond: fails.append(name)

def rejects(raw):
    try:
        core.validate(raw); return False
    except core.StoreError: return True

base = {"id": "x", "topic": "t", "project": "p", "text": "ok"}
check("over-length text is rejected", rejects({**base, "text": "z" * 121}))
check("unknown status is rejected", rejects({**base, "status": "bogus"}))
check("unknown closed_by is rejected", rejects({**base, "closed_by": "someone"}))
check("non-int source_ids are rejected", rejects({**base, "source_ids": ["1"]}))
check("missing project is rejected", rejects({"id": "x", "topic": "t", "text": "ok"}))
check("control characters are stripped",
      core.validate({**base, "text": "a\x00b"}).text == "ab")

# The pages are opened over file://, where injected markup executes with
# local-file read.
evil = core.Item(id="deadbeef", topic="p / t", project="p",
                 text="<script>alert(1)</script> & \"q\"", first_seen="2026-08-29")
core.save([evil]); render.render_all([evil], Path(d))
full = (Path(d) / "full.html").read_text()
check("html escaping: no live script tag", "<script>alert(1)</script>" not in full)
check("html escaping: rendered inert", "&lt;script&gt;" in full)

# A seconds-valued watermark matches every row and silently turns every
# incremental refresh into a full sweep.
try:
    core.write_state({"watermark_epoch": 1788004350, "watermark_unit": "milliseconds"})
    check("seconds-valued watermark is rejected", False)
except core.StoreError:
    check("seconds-valued watermark is rejected", True)
core.write_state({"watermark_epoch": 1788004350945, "watermark_unit": "milliseconds"})
check("milliseconds watermark is accepted", True)

# Distinct project keys must not collide onto one filename and silently
# overwrite each other's page.
check("slug disambiguates colliding keys", core.slug("13.10.2") != core.slug("13-10-2"))

sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && pass=$((pass + 11)) || fail=$((fail + 1))

# ===========================================================================
printf '\nModel response parsing\n'
# ===========================================================================
# Haiku fences its JSON on every observed response AND frequently appends a
# paragraph of reasoning. Stripping only the fence leaves that prose and
# json.loads dies with "Extra data" -- this hit within the first 5 chunks of
# the first real sweep, after a 2-chunk spike showed only clean output.
py - <<'PY'
import sys, os, json
sys.path.insert(0, os.environ["DOT"] + "/lib")
from global_todo.llm import strip_fence

cases = [
    ("fenced then prose", '```json\n[]\n```\n\nAll work items are completed.', []),
    ("fenced with items", '```json\n[{"a":1}]\n```', [{"a": 1}]),
    ("bare array", '[{"a":1}]', [{"a": 1}]),
    ("prose before and after", 'Analysis:\n[{"a":1}]\nThat is all.', [{"a": 1}]),
    ("bracket inside a string", '[{"t":"fix the [broken] link"}]', [{"t": "fix the [broken] link"}]),
    ("escaped quote in string", '[{"t":"say \\"hi\\""}]', [{"t": 'say "hi"'}]),
    ("empty array with prose", 'Nothing open.\n[]\nDone.', []),
]
fails = []
for name, raw, want in cases:
    try:
        got = json.loads(strip_fence(raw))
        good = got == want
    except Exception as e:
        got, good = f"{type(e).__name__}", False
    print(f"  {'PASS' if good else 'FAIL'}  parses: {name}")
    if not good: fails.append(name)

try:
    strip_fence("no array at all")
    print("  FAIL  a response with no array raises"); fails.append("noarray")
except ValueError:
    print("  PASS  a response with no array raises")

sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && pass=$((pass + 8)) || fail=$((fail + 1))

# ===========================================================================
printf '\nRegressions found by running it\n'
# ===========================================================================
# Every case below is a bug that shipped and was caught only by executing the
# tool, never by reading it. Each must FAIL if its fix is reverted.
py - <<'PY'
import sys, os, json, inspect, sqlite3, tempfile, threading
from pathlib import Path as _P
sys.path.insert(0, os.environ["DOT"] + "/lib")
from global_todo import llm, sources

fails = []
def check(name, cond):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}")
    if not cond: fails.append(name)

# --- 1. threading: no live DB handle may reach a function that pools --------
# The original bug: recent_observations() was called from inside the
# verification ThreadPoolExecutor. sqlite3 raised ProgrammingError on every
# project and an outer handler discarded every candidate. Exit 0, all work
# gone. The fix is structural -- _verify takes pre-read evidence, never a
# connection -- so this pins the signature.
params = list(inspect.signature(llm._verify).parameters)
check("_verify takes no database connection", "conn" not in params)
check("_verify takes pre-read evidence", "recent_by_project" in params)
src = inspect.getsource(llm._verify)
check("_verify body never calls a sources DB function",
      "recent_observations" not in src and "connect(" not in src)
check("take_snapshot closes its connection",
      "conn.close()" in inspect.getsource(sources.take_snapshot))
check("snapshot reads inside one transaction",
      "BEGIN DEFERRED" in inspect.getsource(sources.take_snapshot))

# Prove sqlite3 really does reject cross-thread use, so the guard above is
# guarding something real rather than a theory.
db = tempfile.mktemp(suffix=".db")
c = sqlite3.connect(db)
c.execute("CREATE TABLE t (x int)")
boom = []
def touch():
    try: c.execute("SELECT 1")
    except Exception as e: boom.append(type(e).__name__)
t = threading.Thread(target=touch); t.start(); t.join()
c.close()
check("sqlite3 rejects cross-thread use (the hazard is real)",
      boom == ["ProgrammingError"])

# --- 2. error handling: verification must never drop on failure ------------
# Two handlers with opposite policies caused the loss; there is now one.
check("a single named keep-on-failure policy exists",
      callable(getattr(llm, "_keep_unverified", None)))
kept = llm._keep_unverified("p", [{"a": 1}, {"b": 2}], RuntimeError("x"), "batch")
check("keep-on-failure returns the candidates, not []", len(kept) == 2)
vsrc = inspect.getsource(llm._verify)
check("every _verify failure path routes through it",
      vsrc.count("except Exception") == vsrc.count("_keep_unverified"))

# --- 3. trailing prose ------------------------------------------------------
# The real chunk-5 response: valid JSON followed by a paragraph of reasoning.
real = ('```json\n[]\n```\n\nAll work items from 2026-07-14 in the input are '
        'completed. Each "change" and "feature" type has corresponding '
        '"discovery" verification. No work remains explicitly undone.')
try:
    check("the exact chunk-5 response parses", json.loads(llm.strip_fence(real)) == [])
except Exception as e:
    check("the exact chunk-5 response parses", False)

# --- 4. exit code on a partial sweep ---------------------------------------
check("IncompleteSweep exists", hasattr(llm, "IncompleteSweep"))
e = llm.IncompleteSweep("stopped", 3, 1, [{"i": 1}])
check("IncompleteSweep carries its partial results",
      e.added == 3 and e.suppressed == 1 and len(e.items) == 1)

# --- 5. latest.html must not select everything -----------------------------
# first_seen is the SWEEP date, so on a cold start every item shares one value
# and a first_seen filter selected 172 of 172 open items. Filter on observation
# activity instead, which also makes latest and stale two ends of one axis.
import time as _t
from global_todo import render, core as _c
now = _t.time() * 1000
old = _c.Item(id="a1", topic="p / t", project="p", text="old work",
              newest_source_epoch=int(now - 60 * 86400 * 1000), first_seen="2026-08-29")
new = _c.Item(id="b2", topic="p / t", project="p", text="new work",
              newest_source_epoch=int(now - 1 * 86400 * 1000), first_seen="2026-08-29")
import tempfile as _tf
outdir = _P(_tf.mkdtemp())
render.render_all([old, new], outdir)
latest_html = (outdir / "latest.html").read_text()
stale_html = (outdir / "stale.html").read_text()
check("latest excludes stale-dated work despite identical first_seen",
      "new work" in latest_html and "old work" not in latest_html)
check("stale is its mirror, not an overlap",
      "old work" in stale_html and "new work" not in stale_html)
check("render does not filter latest on first_seen",
      "first_seen >=" not in inspect.getsource(render.render_all))

# --- 6. verification-time merge into existing records ----------------------
# Jaccard at 0.7 matched 0 pairs across 172 real open items while three records
# described one piece of stop-hook work (0.278 against each other). Meaning has
# to be judged by something that understands meaning, so verification now sees
# the project's open records and may return merge_into.
tgt = _c.Item(id="aaaa1111", topic="p / t", project="p",
              text="Fix missing stop hook scripts", source_ids=[1, 2])
closed = _c.Item(id="bbbb2222", topic="p / t", project="p",
                 text="already handled", source_ids=[9])
closed.status, closed.closed_by = "dismissed", "user"

fresh, n = llm.apply_merges([tgt, closed],
    [{"text": "Create two missing stop hook scripts", "source_ids": [3],
      "merge_into": "aaaa1111"}])
check("a merge_into folds the candidate into the existing record", n == 1 and fresh == [])
check("merging unions source_ids", tgt.source_ids == [1, 2, 3])
check("merging preserves the target's id and status",
      tgt.id == "aaaa1111" and tgt.status == "open")

# The model must not be able to retire new work by pointing at a closed record.
fresh2, n2 = llm.apply_merges([tgt, closed],
    [{"text": "something new", "source_ids": [4], "merge_into": "bbbb2222"}])
check("merging into a CLOSED record is refused", n2 == 0 and len(fresh2) == 1)
check("the refused candidate survives as new", fresh2[0]["source_ids"] == [4])

# A hallucinated id must not silently discard the candidate.
fresh3, n3 = llm.apply_merges([tgt],
    [{"text": "unrelated", "source_ids": [5], "merge_into": "deadbeef"}])
check("an unknown merge_into keeps the candidate", n3 == 0 and len(fresh3) == 1)

fresh4, n4 = llm.apply_merges([tgt],
    [{"text": "plain new item", "source_ids": [6]}])
check("a candidate with no merge_into is untouched", n4 == 0 and len(fresh4) == 1)

check("only open records are offered to the model",
      "if i.is_open()" in inspect.getsource(llm._verify))

sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && pass=$((pass + 23)) || fail=$((fail + 1))

# A partial sweep must not exit 0: a wrapper cannot otherwise tell 4/110
# chunks from 110/110.
grep -q "return 2" "$DOT/lib/global_todo/cli.py" \
  && ok "refresh returns a distinct non-zero code on a partial sweep" \
  || ko "refresh returns a distinct non-zero code on a partial sweep" "no return 2"

# ===========================================================================
printf '\nCLI and hook\n'
# ===========================================================================
D2="$TMP/s2"
run "$D2" refresh --docs-only >/dev/null
first_id=$(count "$D2" "items[0]['id']")

out=$(run "$D2" done "$first_id")
case "$out" in
  done:*) ok "done closes an item" ;;
  *) ko "done closes an item" "$out" ;;
esac
st=$(count "$D2" "[i['status'] for i in items if i['id']=='$first_id'][0]")
by=$(count "$D2" "[i['closed_by'] for i in items if i['id']=='$first_id'][0]")
[ "$st" = "done" ] && [ "$by" = "user" ] && ok "closure records status and closed_by" \
  || ko "closure records status and closed_by" "status=$st closed_by=$by"

run "$D2" reopen "$first_id" >/dev/null
st=$(count "$D2" "[i['status'] for i in items if i['id']=='$first_id'][0]")
[ "$st" = "open" ] && ok "reopen clears the closure" || ko "reopen clears the closure" "status=$st"

out=$(run "$D2" done ffffffff 2>&1); rc=$?
[ "$rc" != "0" ] && ok "closing an unknown id fails loudly" \
                 || ko "closing an unknown id fails loudly" "exit 0"

# A refresh that did no work must not report success to a wrapper script.
py - "$D2" <<'PY' &
import sys, os, time
sys.path.insert(0, os.environ["DOT"] + "/lib")
os.environ["GLOBAL_TODO_DIR"] = sys.argv[1]
from pathlib import Path
import global_todo.core as core
core.STORE_DIR = Path(sys.argv[1]); core.LOCK = core.STORE_DIR / ".lock"
with core.store_lock():
    time.sleep(3)
PY
sleep 1
run "$D2" done "$first_id" >/dev/null 2>&1; rc=$?
[ "$rc" = "75" ] && ok "lock contention exits 75, not 0" \
                 || ko "lock contention exits 75, not 0" "exit $rc"
wait

# --- inject ----------------------------------------------------------------
blk=$(run "$D2" inject)
case "$blk" in
  *untrusted-data*) ok "injected block is wrapped as untrusted data" ;;
  *) ko "injected block is wrapped as untrusted data" "missing delimiter" ;;
esac
case "$blk" in
  *hookSpecificOutput*) ok "inject emits hookSpecificOutput" ;;
  *) ko "inject emits hookSpecificOutput" "$blk" ;;
esac

# A malformed store must never block a session launch -- but silence would
# make it indistinguishable from a clean worklist, indefinitely.
printf 'not json at all' > "$D2/global-todo.json"
blk=$(run "$D2" inject); rc=$?
[ "$rc" = "0" ] && ok "corrupt store: inject still exits 0" \
                || ko "corrupt store: inject still exits 0" "exit $rc"
case "$blk" in
  *"could not be read"*) ok "corrupt store: emits a visible notice, not silence" ;;
  *) ko "corrupt store: emits a visible notice, not silence" "$blk" ;;
esac
out=$(run "$D2" refresh --docs-only 2>&1); rc=$?
[ "$rc" != "0" ] && ok "refresh refuses to overwrite an unparseable store" \
                 || ko "refresh refuses to overwrite an unparseable store" "exit 0"

# ===========================================================================
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
