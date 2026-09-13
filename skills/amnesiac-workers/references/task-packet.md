# Task packet and state schemas

## The packet

Every attempt is dispatched with the same six-part packet and nothing else. The packet is
rebuilt from scratch each attempt, so it can never accumulate.

| Part                    | Source                               | Rebuilt from                  |
| ----------------------- | ------------------------------------ | ----------------------------- |
| Original goal           | The queue line or incident, verbatim | Master state                  |
| Remaining work          | The TODO items still unchecked       | The queue                     |
| Repo instructions       | `MACHINE.md`, `SPEC.md`, `README.md` | The repo, fetched fresh       |
| Current code            | The work tree at its current commit  | Git                           |
| Latest verifier failure | Command, exit code, literal output   | `state.json`                  |
| Durable discoveries     | Validated records                    | `facts.json`, `blockers.json` |

**The packet must also tell the worker how to give up.** A live three-attempt run against a
deliberately unsatisfiable task showed why. With no blocker channel in the packet, the worker
diagnosed the contradiction, changed nothing, and reported `done` with the verifier still red.
The loop had no way to learn that and would have drained its whole retry budget re-confirming an
impossibility. Adding one paragraph naming `.herdr/blockers.json`, its shape, and the rule to
record only what a command printed changed the outcome on the next attempt: the worker wrote a
valid blocker, and it had run the *reciprocal* experiment first, flipping the implementation to
prove the other test then failed. That is evidence a supervisor can act on, produced because the
packet asked for evidence rather than an explanation.

Absent from the packet, permanently: the prior worker's transcript, its plan, its tool calls,
its stated intent, and any summary of them. A summary is the contamination in compressed form,
not a mitigation for it.

The packet is model-agnostic by construction. Nothing in it refers to who produced the previous
attempt, so attempt 3 can run on a different model than attempt 2 with no translation step.

## What the master holds and what it derives

The master persists exactly what cannot be recomputed:

```json
{
  "schema": 1,
  "unit_id": "fix-auth-timeout-9f2a1c",
  "attempt": 7,
  "retry_budget": 3,
  "verification": {
    "command": "./verify.sh",
    "exit_code": 1,
    "excerpt": "test_refresh_expired_token expected 401, received 500"
  }
}
```

Everything else is derived at packet-build time and never stored:

| Derived         | From                                |
| --------------- | ----------------------------------- |
| Files changed   | `git diff --name-only <base>..HEAD` |
| Current commit  | `git rev-parse HEAD`                |
| Completed items | Queue lines marked `[x]`            |
| Remaining items | Queue lines marked `[ ]`            |

The schema rejects `commit`, `changes_since_start`, and `todo_remaining` as unpermitted fields.
Storing a second copy of a fact git already owns creates two sources of truth that drift the
moment an attempt crashes between the commit and the state write.

## facts.json

Worker-authored, so untrusted. Validated at the boundary before any record enters a packet.

```json
{
  "schema": 1,
  "facts": [
    {
      "claim": "httpx 0.28 removed the app= constructor shortcut",
      "observed_via": "python3 -c 'import httpx; print(httpx.__version__)'",
      "exit_code": 0,
      "excerpt": "0.28.1",
      "observed_at": "2026-09-12T21:40:00-04:00"
    }
  ]
}
```

Every field is required and the schema is closed. The evidence fields are what make a belief
unwritable, because no command emits "the auth architecture is wrong" as its output. The
banned-lexeme check on `claim` is a backstop for the case where a worker fabricates a plausible
`observed_via` and then editorializes in the claim.

A fact earns its place only if it is both durable and non-obvious from the repo. A test failure
is neither, because the next verifier run reproduces it. A library's actual runtime version, an
undocumented API response shape, and a rate limit discovered by hitting it all qualify.

## blockers.json

Same evidentiary shape, plus `blocks`, which names the TODO item that cannot proceed. A blocker
escalates to a human; a fact only flows into the next packet. That difference in consequence is
why they are separate files rather than a flag on one record type.

```json
{
  "schema": 1,
  "blockers": [
    {
      "need": "SUPABASE_SERVICE_KEY is unset in the work tree",
      "blocks": "Implement token refresh",
      "observed_via": "printenv SUPABASE_SERVICE_KEY",
      "exit_code": 1,
      "excerpt": "(unset)",
      "observed_at": "2026-09-12T21:40:00-04:00"
    }
  ]
}
```

## Validation

```bash
python3 scripts/validate_state.py <path>
```

Exit 0 valid, 1 invalid with reasons on stdout, 2 unreadable file. Run it on every worker-authored
file before promoting records into a packet. A file that fails validation is dropped with its
reasons escalated, never partially salvaged, because deciding which half of a contaminated ledger
to keep is exactly the judgment call this design removes.

Limits worth knowing before writing a record: `claim` and `blocks` cap at 200 characters, `need`
at 400, `excerpt` at 2000, and each collection at 50 records. `need` gets the extra room because a
blocker has to name both conflicting parties and what each produced; a real one measured 276
characters and the original shared 200-character cap rejected it. The record cap matters most. An unbounded ledger
becomes a transcript by another name and reintroduces the growth this whole design exists to stop.
