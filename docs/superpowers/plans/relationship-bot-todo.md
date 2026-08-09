# Relationship Bot — Programme Tracker

**Spec:** [2026-07-26-whatsapp-relationship-memory-design.md](../specs/2026-07-26-whatsapp-relationship-memory-design.md)
**Phase 1 plan:** [relationship-bot-plan.md](relationship-bot-plan.md)
**Repo:** `~/Documents/Projects/prmm-bot` (not yet created)

---

## Blocking prerequisites

Tasks 1–10 build and test entirely against fakes and need none of these. The
gates below bite at exactly two points: **Task 2 Step 5** (applying migration 009
to the real database) and **Task 11 Step 11** (pairing a real device and running
the smoke test).

- [ ] **Choose the WhatsApp number.** *Gates Task 11 Step 11.*
      A dedicated number confines a ban to the bot; a personal number puts your
      real WhatsApp account at risk, and the linked device can see every chat on
      it. OpenClaw's own docs recommend a dedicated number.
- [ ] **Confirm which Postgres receives migration 009.** *Gates Task 2 Step 5 and
      Task 11 Step 11.* OpenBrain's README describes Postgres 17 + pgvector on a
      Mac Mini; the voice host runs a separate `postgres:16`. These are different
      instances.
- [ ] **Verify Ollama** on the target host serves a model capable of structured
      extraction. *Gates Task 11 Step 11.*
- [ ] **Decide whether OpenBrain's write endpoints need auth.** *Gates Task 11
      Step 11.* `/people`, `/interactions`, and `/clarifications` accept
      unauthenticated writes as specified. Either confirm the API is
      network-isolated or set `PRMM_OPENBRAIN_TOKEN` and add a dependency check
      on the router.

**Not a gate on this project**, but do it anyway: rotate the leaked MySQL root
credential sitting in plaintext in `~/.claude/projects/*.jsonl`.

**Deferred to Phase 2, deliberately:** `jina/jina-embeddings-v2-base-en` is not
needed yet. `people.embedding` exists in the schema but nothing in Phase 1 writes
or queries a vector — identity resolution is string-based. Verify the embedding
model when Phase 2 adds semantic person lookup.

## Phase 1 — Capture path

Produces working software: a bot that reads the group, extracts people and
facts, resolves identity, and stores to OpenBrain.

- [ ] **Task 1** — Project scaffold, config, domain types
- [ ] **Task 2** — Migration 009 (`people`, `interactions`, `triggers`, `clarifications`, `thought_people`, `resolution_log`, `thoughts.visibility`)
- [ ] **Task 3** — Message normalisation + JID allowlist routing
- [ ] **Task 4** — Debounced capture buffer, per-channel batching
- [ ] **Task 5** — Extraction schemas (zod) + heuristic relevance gate
- [ ] **Task 6** — Ollama extractor with schema validation and one retry
- [ ] **Task 7** — Identity scoring + three-way resolution ⚠️ _your tuning call_
- [ ] **Task 8** — OpenBrain HTTP client + repository
- [ ] **Task 9** — Write-ahead queue (offset-safe drain, serialised, quarantine for poison ops) + `QueuedRepository` decorator
- [ ] **Task 10** — Baileys session, atomic creds, reconnect policy
- [ ] **Task 11** — FastAPI endpoints + end-to-end wiring + smoke test

### Phase 1 exit criteria

- [ ] `pnpm test` green, nothing skipped
- [ ] A group message lands in `people`, `thoughts`, and `interactions`
- [ ] A DM-captured memory lands with `visibility = 'private'`
- [ ] Killing OpenBrain mid-capture reports `degraded`; writes replay on restart
      without duplicating rows
- [ ] Killing Ollama mid-capture reports `parked`; the batch re-extracts later
- [ ] The same `op_id` posted twice returns one id and creates one row
- [ ] `SIGTERM` during an in-flight capture loses nothing
- [ ] A group with disappearing messages enabled still captures
- [ ] `resolution_log` records one row per candidate above the confidence floor

---

## Phase 2 — Proactive path

Not yet planned. Gets its own plan document once Phase 1 exits. Scope from the
spec, for reference:

- Trigger rules for `birthday`, `reconnect`, `commitment`, `context`, `followup`
- Hourly scheduler tick with a 3/day cap and quiet hours
- Nudge routing: owner's DM, group only when both users are involved
- Draft composition from person context
- Clarification queue delivered by DM, with expiry
- Approval reactions: 👍 approve, 👎 dismiss, `snooze 2w`
- Visibility enforcement suite — assert no read path leaks a `private` row to
  the other user
- Promotion flow: bot asks before moving a private fact to `shared`
- **Consumers for schema Phase 1 creates but never writes:** `triggers`,
  `thought_people` (multi-person memories — Phase 1's `MemoryCandidate.about` is
  a single subject by design), `people.embedding` (semantic "who do we know
  who…" lookup), and `interactions.status = 'unextracted'`
- Answering a clarification: resolve the identity, then store the `heldMemories`
  the clarification has been carrying

---

## Decisions already made

Recorded so they don't get relitigated mid-build.

| Area            | Choice                                                                                     |
| --------------- | ------------------------------------------------------------------------------------------ |
| Runtime         | Node 22, **not Bun** — Baileys targets Node; OpenClaw documents Bun breaking their gateway |
| Package manager | pnpm, matching OpenClaw                                                                    |
| Transport       | Baileys linked device, pinned `7.0.0-rc13`                                                 |
| Storage         | Hybrid — relational tables plus `thoughts` vectors, one Postgres                           |
| Write path      | openbrain-mcp FastAPI, so bot / Claude Code / future IVR share one path                    |
| Extraction      | Ollama local by default; cloud override via config                                         |
| Resolution      | Cautious bands (`high 0.9`, `low 0.35`, tie margin `0.05`) + `resolution_log`              |
| Outbound        | Drafts only. The bot never messages third parties.                                         |
| Visibility      | Group captures `shared`; DM captures `private`; promotion needs consent                    |

---

## Open questions

Carried from the spec. None block Phase 1.

- [ ] How long should an unanswered clarification live before expiring?
- [ ] Should low-confidence extractions carry a default `expires_at`?
- [ ] Can a user read their own private rows back through search, or only
      correct them when the bot asks?
- [ ] Does the group need a `/people` browse command, or is Claude Code
      querying OpenBrain enough?

---

## Known risks

- **Baileys violates WhatsApp's ToS.** Ban risk is real and falls on whichever
  number gets linked. Accepted as exploratory; revisit before any wider use.
- **`thoughts.visibility` is enforced in application code, not by the database.**
  Any future client that queries Postgres directly — including the IVR service —
  must filter on it. A row-level security policy would be the durable fix.
- **The FastAPI endpoints in Task 11 are new**, and `/capture` is pre-existing
  and *not* verified to accept `person_id`/`visibility`/`op_id`. FastAPI silently
  drops undeclared fields, so visibility could be discarded server-side while
  every client test stays green. Task 11 Step 1 exists to check this first.
- **`db.py` helper names** (`fetch_all`, `fetch_one`, `execute`) are assumed;
  verify against the real module before running.
- **Ollama's `llama3.1:8b` may extract poorly.** The retry-then-park path keeps
  bad output from corrupting memory, but if the park rate is high, switch models
  before tuning anything else.
