# Personal Relationship Memory — WhatsApp Capture Bot

**Status:** Built. Capture, extraction, resolution and storage ship in
`prmm-bot`; triggers and nudges do not — see [Phase
1.5](2026-07-26-phase-1.5-consolidation-design.md) (merged as PR #1,
2026-07-27), which re-scopes them to Phase 2 and supersedes the storage
decision below.
**Date:** 2026-07-26
**Source concept:** `Personal_Relationship_Memory_Model` draft v0.1

> **Where this document is authoritative.** The scope, decisions, and rationale
> below describe the system as designed and, except where a line says
> otherwise, as built. Four things were overtaken by Phase 1.5, each marked
> where it appears: the `Database` decision (the bot's tables now live in the
> `voice` database under a `prmm` schema), proactive nudges (specified here,
> deferred to Phase 2 there), the `@bot remember` capture trigger (removed by
> Phase 1.5's mention gating), and the 📌 acknowledgement reaction (specified
> here, actually shipped in Phase 1.5, not Phase 1).

## Goal

Two people share one relationship memory. A bot sits in their WhatsApp group,
extracts durable facts about the people they discuss, and surfaces those facts
later at the moment they matter.

The draft describes a single-user system. This design serves two users who
maintain one shared set of relationships, so ownership becomes explicit: a
relationship belongs to one person, and a follow-up may belong to the other.

Three channels carry different traffic. The group captures conversation. A
private DM per user carries clarification and viewpoint. Nudges route to
whoever owns them. Separating these keeps the shared room quiet and lets each
user tell the bot things they would not say in front of the other.

## Scope

**In scope**

- Ambient capture from one WhatsApp group containing two people and the bot
- A private DM channel per user for clarification, correction, and viewpoint
- Extraction of people, memories, commitments, and dates
- Identity resolution against known people, with clarification when uncertain
- Proactive nudges for birthdays, commitments, reconnect cadence, and dates
  lifted from conversation
- Draft messages the user copies and sends

**Out of scope**

- Messaging third parties. The bot posts drafts to the group or a DM; the user
  sends them. See Security below.
- Reading the users' other WhatsApp conversations or DMs from anyone else
- A web or mobile interface
- Voice. The schema anticipates it; this build does not implement it.

## Prior art

Two existing systems supply most of the machinery.

**OpenClaw** (`~/Documents/Projects/openclaw`) runs WhatsApp through Baileys
7.0.0-rc13 as a linked device. This project borrows its patterns and builds
standalone rather than shipping as an extension. Patterns worth copying:

- Atomic credential writes with `.bak` restore. A corrupted `creds.json` forces
  a full re-pair.
- `fetchLatestBaileysVersion()` before socket construction
- `makeCacheableSignalKeyStore` for signal key performance
- `syncFullHistory: false`, `markOnlineOnConnect: false`
- A watchdog tracking transport liveness and message liveness separately, so a
  quiet connection survives
- `maxPerDay` throttling on proactive delivery, default 3

**OpenBrain** (`richardahasting/openbrain-mcp`) is a personal memory system —
Postgres 17 with pgvector, Ollama embeddings — and an earlier draft of this spec
routed all writes through it. **That was wrong, on three counts verified against
the repository rather than its README:**

1. **We have read-only access.** `permissions: {push: false, admin: false}`. It is
   not our project. Every option that required adding endpoints, extending
   `capture_thought`, or landing a migration in its `migrations/` directory was
   never available.
2. **It exposes no write API.** `main.py` serves `POST /mcp` (JSON-RPC for LLM
   tool-calling) plus read-only `/export`, `/backup`, `/metrics`. The "one shared
   write path" that justified the coupling does not exist.
3. **Adding `visibility` to its `thoughts` table would leak private DMs.** None of
   its read paths — `/export`, `/backup`, `search`, `browse`, `digest` — filter on
   a column they do not know about. The private channel would have been a trap
   from the first message.

A fourth risk stands even with write access: `008_switch_to_jina_embedding.sql`
shows the embedding model has already changed once, which would silently
invalidate any person vectors we stored alongside.

**What we keep is the column design**, which is free and needs no permission.
OpenBrain's `thoughts` table got the hard parts right, and `memories` borrows
them directly:

| Draft object | This system                                                                             |
| ------------ | --------------------------------------------------------------------------------------- |
| Memory       | `memories` — `confidence`, `trust_weight`, `verified_at`, `expires_at`, `singleton_key` |
| Relationship | `memory_people` — one memory, several subjects                                          |
| Interaction  | `interactions` — channel, participants, excerpt                                         |
| Person       | `people` — the object neither system had                                                |

`singleton_key UNIQUE` implements auto-replace, which relationship facts need:
employers change, titles change, plans slip.

## Decisions

| Decision          | Choice                                   | Rationale                                                                                                                                                                                              |
| ----------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Topology          | Group plus a private DM per user         | Ambient capture where the conversation already happens                                                                                                                                                 |
| Clarification     | DM only, never the group                 | A question in the group derails a live human conversation                                                                                                                                              |
| DM visibility     | Private by default; promote on request   | A private channel that leaks silently is worse than none                                                                                                                                               |
| Nudge routing     | Owner's DM; group when both are involved | Keeps the shared room quiet and the daily cap effective                                                                                                                                                |
| Transport         | Baileys linked device                    | Reads existing groups; no Official Business Account gate                                                                                                                                               |
| Build target      | Standalone service                       | Full control; avoids coupling to OpenClaw's release cycle                                                                                                                                              |
| Storage           | Relational tables, own schema            | Structured triggers now; semantic recall in Phase 2                                                                                                                                                    |
| Database          | The bot's own database on aorus4         | Colocated with the voice stack; no shared schema. **Superseded by Phase 1.5** — the tables moved into the `voice` database under a `prmm` schema, because joining `person_contacts` needs one database |
| Write path        | Direct Postgres                          | The guard and the write commit in one transaction                                                                                                                                                      |
| Extraction model  | Ollama local, cloud override in config   | The data describes people who never consented to a cloud API                                                                                                                                           |
| Resolution policy | Cautious, with a `resolution_log`        | False merges cost far more than false splits                                                                                                                                                           |
| Outbound          | Drafts only                              | An extraction bug must not reach a third party                                                                                                                                                         |
| Repository        | New standalone repo                      | Clean boundary and independent deploy                                                                                                                                                                  |

### Why the Cloud API lost

Meta's Groups API supports group messaging and delivers full message text with a
`group_id` field. It requires an Official Business Account: business
verification, two-step verification, an approved display name, and thirty days
on the platform. It also forbids interactive messages in groups, which removes
the buttons the approval flow wants.

Baileys carries a real cost in exchange: it violates WhatsApp's terms of service
and risks a ban on the linked number. This build accepts that cost as
exploratory. See Prerequisites.

## Architecture

```
  WhatsApp group (two users + bot)      DM: user A      DM: user B
         │  capture                          │ clarify + nudge │
         └──────────────┬───────────────────┴─────────────────┘
                        │  one Baileys linked device
                        ▼
  prmm-bot — standalone Node/TypeScript
    transport/   Baileys socket, watchdog, JID routing
    capture/     debounce and batch
    extract/     LLM to structured candidates
    resolve/     identity resolution
    ask/         clarification queue, DM-delivered
    store/       sole I/O boundary
    trigger/     scheduler tick
    compose/     draft generation
    approval/    reactions to outcomes
         │  postgres.js
         ▼
  Postgres on aorus4 — the bot's own database
    people, memories, memory_people, interactions,
    triggers, clarifications, resolution_log, write_ops
         ▲
         └── future consumer: IVR / voice-platform
```

The bot holds no relationship state of its own. Postgres is the only durable
home for a fact; the bot's disk carries just its Baileys credentials and the
write-ahead queue. The queue is a transient buffer, not a second store — it
holds writes Postgres has not yet accepted, and it empties on replay. A voice
service therefore becomes a second reader of the same tables rather than an
integration project.

Module boundaries stay strict. `transport` knows nothing about relationships.
`extract` never touches the database. `store` alone performs I/O, behind a
repository interface, so swapping the write path later touches one module.

## Data model

Migration `migrations/001_init.sql`, the first migration of a new database.
Every table below is created by it; nothing pre-exists. (Earlier drafts numbered
this `009` and described it as additive, because they planned to land it inside
OpenBrain's migration series. That plan was rejected — see Prior art — and the
numbering went with it.)

```sql
people (
  id, user_id,                    -- who owns this relationship
  canonical_name, aliases TEXT[],
  phone, email, company, role, relationship_type,
  birthday DATE, timezone, comm_preference,
  first_met_at, first_met_context,
  last_interaction_at, next_nudge_at, cadence_days,
  status TEXT DEFAULT 'active',    -- no other value is written yet — see Open questions
  visibility,      -- 'shared' | 'private'
  metadata JSONB, created_at, updated_at
)
-- No embedding column and no pgvector. Phase 1 resolves identity by string;
-- the vector column arrives with Phase 2's semantic search.

interactions (
  id,
  person_id BIGINT REFERENCES people(id) ON DELETE CASCADE,
  occurred_at, channel,
  summary, raw_excerpt, captured_by,
  participants BIGINT[],          -- everyone present, not just the subject
  memory_id BIGINT REFERENCES memories(id) ON DELETE SET NULL,
  status,          -- extracted | unextracted
  created_at
)
-- No visibility column of its own — see "Interactions and visibility" below.

triggers (
  id, person_id, owner_user_id,
  kind,        -- birthday | followup | commitment | reconnect | context
  due_at, reason, payload JSONB,
  status,      -- pending | sent | approved | dismissed | snoozed
  sent_at, resolved_at, created_at
)

memory_people (
  memory_id BIGINT REFERENCES memories(id) ON DELETE CASCADE,
  person_id BIGINT REFERENCES people(id) ON DELETE CASCADE,
  role
)

resolution_log (
  id, candidate_name, chosen_person_id, score,
  action,      -- match | ask | create — resolver.ts's actual outcomes
  confirmed_person_id, created_at
)

clarifications (
  id, asked_user_id, kind,   -- identity | ownership | fact | viewpoint
  question, context JSONB,
  status,                    -- pending | answered | expired
  answer, answered_at, created_at
)

memories (
  id, content, user_id, category, source,
  confidence, trust_weight, verified_at, expires_at,
  singleton_key UNIQUE,          -- auto-replace: employers and plans change
  visibility,                    -- 'shared' | 'private'
  status TEXT DEFAULT 'active',  -- no other value is written yet — see Open questions
  metadata, created_at, updated_at
)

write_ops (op_id PRIMARY KEY, kind, result_id, created_at)
```

Four choices carry weight:

**Commitments live in `triggers` under `kind='commitment'`.** They share every
field and the whole delivery path. A separate table would duplicate structure to
preserve a distinction that exists only in prose.

**`memory_people` is a join table.** "Sarah introduced me to Marcus" is one
memory about two people, and referral tracking hits that case immediately.

**`owner_user_id` on triggers stays separate from `people.user_id`.** One user
may meet someone while the other owes the follow-up. Collapsing the two columns
would erase who is on the hook.

**`visibility` defaults to `shared` on both `people` and `memories`; DM capture
overrides it to `private`.** The default matches group capture, where both users
are present anyway. The override protects the channel that only works if it is
genuinely private — and because this is our own schema, every read path is ours
to filter. That was the decisive argument against writing into OpenBrain, whose
`/export` would have returned private rows it never knew to exclude.

**`interactions` has no `visibility` column of its own.** Every current read
path reaches it through the subject: `lastSpoke` joins `interactions` to
`people` and filters on the _person's_ visibility, and it returns only
`occurred_at` — never `raw_excerpt` or `summary`. That keeps today's answering
surface correct: a shared person's timestamp is fine to reveal, and no content
is exposed either way. But the column exists and holds real captured text, and
nothing stops a future feature from reading `raw_excerpt` straight off a
private-DM-sourced row for a _shared_ person — visibility scoped to the person
says nothing about the channel the interaction itself came from. That gap is
tracked in Open questions rather than closed here, because closing it means
choosing between a second visibility column and a rule that content-bearing
reads always join through `memories` instead.

**`write_ops` is an idempotency ledger, claimed in the same transaction as the
write it guards.** Over HTTP the two could not be atomic: a crash between "insert
row" and "record op_id" left the write done and unrecorded, so the queue's replay
duplicated it. Direct Postgres closes that window.

Phase 2 adds `people.embedding` to answer the question SQL cannot: who among our
contacts would care about this launch. It is deliberately absent here, because
nothing in Phase 1 reads or writes a vector.

## Pipelines

### Capture

Group message → normalize → buffer → debounce 90 seconds → relevance gate →
extraction → resolution → store → 📌 reaction.

This document originally offered `@bot remember` as a second flush trigger,
forcing immediate extraction without waiting out the debounce. **Phase 1.5
removed it.** Its mention gate routes every message addressed to the bot to the
question path before the buffer sees it, so `@bot remember …` is now read as a
question and refused. Nothing replaced the explicit-capture trigger; Phase 1.5's
open questions carry the decision.

The 📌 reaction is likewise specified here and was not built in Phase 1 — it is
Phase 1.5 work.

A cheap relevance gate runs first and answers one question: does this batch
mention a person, commitment, or date? Only batches that pass reach the
structured extractor. Most group traffic carries no relationship content, and
extracting from all of it wastes tokens.

The extractor returns candidates with confidence scores, never final records:

```
{ people:      [{ name, aliases?, company?, context, confidence }],
  memories:    [{ about, content, category, confidence }],
  commitments: [{ owner, what, due?, confidence }],
  dates:       [{ person, kind, date, confidence }] }
```

### Identity resolution

Resolution scores each candidate against known people using name and alias
matches, company match, and co-occurrence with people already present in the
conversation. Three outcomes follow:

```
score ≥ high         → action: match  — use the existing person
low < score < high   → action: ask    — enqueue an `identity` clarification, DM only
score ≤ low          → action: create — a new person
```

These are `resolve`'s actual three outcomes; there is no separate
`pending_resolution` status field anywhere in the schema. The middle band's
"parking" is the `clarifications` row itself — `kind='identity'`, `status='pending'`
— not a flag on the candidate. `resolution_log.action` records which of the
three happened, and `confirmed_person_id` is filled once the ask resolves.

Phone and email are stored on `people` but are not scoring signals in Phase 1:
the extractor's candidate shape carries neither, so there is nothing to match
against. They become signals when a candidate source that supplies them exists —
`person_contacts` in Phase 1.5, contact cards later. Embedding similarity is
Phase 2, for the same reason the column is: nothing writes a vector yet.

Start cautious: set the bands so uncertain cases produce questions. Write every
decision to `resolution_log` with its score and the outcome the user confirmed.
Tune the bands from that data after several weeks rather than from guesswork.

The asymmetry drives the policy. A false merge fuses two histories silently and
forces an audit of every attached memory to unwind. A false split produces two
records — recoverable, in principle, by merging them, though **no merge command
exists yet**; today "merges in seconds" describes the cost of the fix a human
makes by hand in SQL, not a built feature. `people.status` carries no `merged`
value and nothing writes one. Building that command is Open questions material,
not a Phase 1 deliverable — the asymmetry argument holds either way, since even
a manual fix is cheaper than unwinding a silent false merge.

`resolve` returns a decision. It never writes.

### Clarification

Uncertain resolutions, ambiguous ownership, and low-confidence extractions
enqueue a clarification instead of a guess. The bot delivers it by DM to one
user, never to the group.

`clarifications.kind` names what is being asked, and each value has a producer:
`identity` from the resolution band above, `ownership` when a commitment names
no clear owner, `fact` when an extraction lands below the confidence floor, and
`viewpoint` when the group discusses something the bot cannot adjudicate from
the transcript — the channel this design exists to provide, where the bot asks
one user what they made of a conversation both were in.

Routing the question privately is what makes cautious resolution affordable.
Asking "which Sarah?" in the group interrupts a live human conversation to
service the bot; asking in a DM costs the other person nothing. Clarification
traffic and nudge traffic therefore draw on separate attention budgets, and the
daily nudge cap never competes with accuracy.

Clarifications expire. An unanswered question stops mattering, and a queue that
accumulates stale prompts trains the user to ignore the channel.

### Visibility

Anything captured in a DM defaults to `private` and belongs to its author.
Anything captured in the group defaults to `shared`, because both users were
present.

When the bot judges a private statement to be a factual correction rather than a
viewpoint, it asks the author whether to share it. One tap promotes the row to
`shared`.

The bot never promotes silently. A private channel that leaks becomes a trap:
the user believes they are speaking privately while seeding the shared memory,
and no later correction undoes what the other person already read. Asking costs
one tap; guessing wrong costs the channel's entire purpose.

### Triggers and approval

An hourly tick queries due triggers, applies a daily cap of 3 and quiet hours,
then composes. Quiet hours are 22:00–08:00 in the recipient's own timezone,
taken from their config entry and evaluated per recipient. For a trigger owned
by one user, only that user's window matters. For a trigger delivered to the
group, both users are recipients, so it waits for **both** windows to close —
the union, not the earlier one; firing the moment either user's night ends
would still land inside the other user's. The range is configurable through
`PRMM_QUIET_HOURS`. A trigger due inside the window waits for the next tick
after it closes; it is deferred, never dropped. Five kinds fire: `birthday`,
`reconnect` when cadence elapses,
`commitment` on an explicit promise, `context` from a date lifted out of a
memory, and `followup` after a meeting.

Delivery follows ownership. A trigger owned by one user arrives in that user's
DM. A trigger touching a contact both users know posts to the group, where
either can act on it.

The bot posts a draft. 👍 approves, 👎 dismisses, and a reply of `snooze 2w`
defers. Approval renders copy-pasteable text. In a DM the reacting user is
unambiguous; in the group the bot records who reacted.

Throttling matters more than it appears. An unthrottled relationship bot becomes
noise within a week, and that failure stays silent because the users simply stop
reading it.

## Error handling

| Failure                | Response                                                    |
| ---------------------- | ----------------------------------------------------------- |
| Credential corruption  | Atomic write, `.bak` restore                                |
| Connection loss        | Dual-signal watchdog, exponential backoff                   |
| Postgres unreachable   | On-disk write-ahead queue, replay on recovery               |
| Extraction failure     | On-disk retry queue, retried on next batch; report `parked` |
| Malformed model output | Validate against schema, retry once, then `parked`          |
| Ambiguous identity     | Enqueue an `identity` clarification and ask                 |

**Two on-disk queues, not one, because they hold different things and empty on
different conditions.** The write-ahead queue guards Postgres writes — a
`captureMemory` or `upsertPerson` call that failed because the database was
briefly unreachable. It replays once Postgres answers again, and a successful
replay empties it. The retry queue is unrelated: it holds whole batches that
never reached a person or a memory because extraction itself failed or returned
something the schema rejects. It has no database dependency to wait out — it
retries extraction directly and empties when that succeeds. Nothing routes an
extraction failure into the write-ahead queue; `interactions` requires a
`person_id`, and a batch that never resolved one has no row to hold a place
for. `interactions.status = 'unextracted'` is the narrower, later case: a
person did resolve, but no memory came out of the batch.

Without the write-ahead queue, a thirty-second Postgres blip eats a memory and
leaves no trace of what vanished — earlier drafts routed writes through
OpenBrain over HTTP, and the queue outlived that plan because a local database
can be unreachable too.

**No failure is silent.** A `skipped` batch (the relevance gate) and an
`ignore`d message (unknown sender, unresolved `@lid`) are the two exceptions —
both are correct outcomes, not failures, and each is logged. Everything that
_could_ be a failure — a batch that could plausibly have held a fact —
either writes a durable row or leaves a claimed file in one of the two queues.

## Security and privacy

**The bot never messages third parties.** Baileys pairs as a linked device, so a
bot paired to a personal number can send messages indistinguishable from the
user, to anyone. An extraction bug that fires a draft at a client cannot be
recalled. Approved drafts render as text the user sends.

**Extraction runs locally by default.** This system stores personal details
about people who never agreed to appear in it. Ollama keeps that data on the
host. A config flag permits a cloud model when quality demands it.

**Channel scope stays narrow.** An allowlist admits exactly one group JID and
exactly two DM JIDs. The linked device can observe every chat on the number; the
bot discards everything else before routing. An unknown sender reaching the DM
path receives no reply and writes nothing.

**Private stays private.** Rows captured in a DM carry `visibility='private'`
and belong to their author. Every read path filters on visibility, including
search, nudge composition, and any future IVR client. Promotion to `shared`
happens only after the author agrees, and the bot records who promoted what.

**Credentials stay out of the repository.** Connection strings load from the
environment. The Baileys credential directory holds a live WhatsApp session and
requires mode 700.

**The bot's data stays in the bot's database.** Nothing is written into
OpenBrain, which we cannot modify and whose read paths would expose private rows
through `/export`. This design ran Phase 1 in `prmm-db`, its own container — a
separate host from `voice`, not a colocated one, so a Phase 1 IVR read would
have crossed a network hop and had no join available. **Phase 1.5 corrects
this** by moving the tables into `voice` outright: the only way to a real join
is one database, and Postgres has no cross-database join without
`postgres_fdw` or `dblink`, neither used here.

**Third-party data lands in a durable store.** People discussed in the group
acquire durable records they never consented to. Two mitigations follow, and
**neither shipped in Phase 1** — both are named here because the obligation is
real, not because it is met:

- **Deletion by person.** `DELETE FROM people WHERE id = $1` cascades through
  the real foreign keys shown in the Data model above: `interactions.person_id`
  and both columns of `memory_people` are declared `ON DELETE CASCADE`. What
  does **not** cascade: the `memories` rows themselves survive with one fewer
  subject rather than being deleted (a memory about two people should outlive
  either one's individual deletion), and `interactions.participants BIGINT[]`
  cannot carry a foreign key at all, so a deleted id lingers in that array on
  every interaction they were merely present for. Nothing exposes any of this —
  no command, no module, no operator script. Today it is a manual SQL statement
  that the array case makes incomplete even when run by hand.
- **Expiry for low-confidence extractions.** `memories.expires_at` exists and
  stays null; no default is applied and nothing sweeps expired rows.

Both are tracked in Open questions, which is the honest status: designed, owed,
unbuilt.

## Testing

- `transport`: mock the Baileys event emitter; no live WhatsApp in CI
- `extract`: golden fixtures pairing real transcripts against expected output
- `resolve`: table-driven cases covering the ambiguous band
- `store`: contract tests running the same suite against the real `PgRepository`
  and an in-memory fake, so both honour one interface
- Idempotency: replay a queued write whose `write_ops` row already exists and
  assert no duplicate lands. This is the guarantee that justified direct
  Postgres over HTTP, and an untested guarantee is a claim.
- Visibility: assert every read path filters `private` rows out of the other
  user's results. This deserves its own suite; a regression here leaks personal
  content between two people who trusted the channel.
- Integration: ephemeral Postgres via testcontainers running real migrations
- Manual: a staging group before touching a real one

## Prerequisites

1. **Choose the WhatsApp number.** Undecided. A dedicated number limits the
   blast radius of a ban and restricts the linked device to the bot's group. A
   personal number risks the user's real WhatsApp account. OpenClaw's own
   documentation recommends a dedicated number. Settle this before QR pairing.
2. **~~Create the bot's database on aorus4~~ — superseded by Phase 1.5.** This
   prerequisite described Phase 1's own `prmm-db` container: `CREATE DATABASE
prmm` with a role the bot owns, then apply `migrations/001_init.sql`. That
   topology shipped, then Phase 1.5 replaced it — the tables now live in a
   `prmm` schema inside the `voice` database instead, so a fresh install
   applies `002_voice_schema.sql` against `voice`, not this step. Kept here,
   struck through, so the migration's history is legible. No pgvector needed
   either way: Phase 1 resolves identity by string, so nothing writes an
   embedding. The extension arrives with Phase 2's semantic person search.
3. **Verify Ollama** serves a model capable of structured extraction on the
   target host. No embedding model is needed — Phase 1 writes no vectors, and
   the embedding model arrives with Phase 2's semantic search.
4. **Rotate the leaked MySQL root credential** found in plaintext in Claude Code
   session transcripts under `~/.claude/projects/`. It belongs to another stack
   and gates nothing here; it is listed because this project's own session
   transcripts are where it surfaced, and the finder owes the fix.

## Future: IVR

The voice platform reads the same tables. `people.phone` supports caller
identification, and Phase 2's `people.embedding` will support "who am I about to
talk to." Nothing in this design blocks that path, provided relationship state
stays in Postgres and out of the bot.

## Open questions

- Does the group need a `/people` command for browsing, or is direct SQL enough?
  (An earlier draft offered "Claude Code querying OpenBrain" as the alternative;
  no relationship data is written there, so it was never one.)
- **How is deletion by person exposed?** The obligation is stated under Security
  and nothing implements it. A `/forget <name>` command, an operator script, and
  "manual SQL, documented" are the candidates.
- Should low-confidence extractions expire automatically, and after how long?
  `expires_at` exists and is never set; whatever answer this gets has to also
  decide what sweeps the expired rows.
- How long should an unanswered clarification live before it expires?
- Should a user be able to read their own private rows back through search, or
  only correct them at the moment the bot asks?
