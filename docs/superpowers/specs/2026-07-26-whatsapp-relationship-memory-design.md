# Personal Relationship Memory — WhatsApp Capture Bot

**Status:** Design approved, ready for planning
**Date:** 2026-07-26
**Source concept:** `Personal_Relationship_Memory_Model` draft v0.1

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

| Draft object | This system |
| --- | --- |
| Memory | `memories` — `confidence`, `trust_weight`, `verified_at`, `expires_at`, `singleton_key` |
| Relationship | `memory_people` — one memory, several subjects |
| Interaction | `interactions` — channel, participants, excerpt |
| Person | `people` — the object neither system had |

`singleton_key UNIQUE` implements auto-replace, which relationship facts need:
employers change, titles change, plans slip.

## Decisions

| Decision          | Choice                                    | Rationale                                                    |
| ----------------- | ----------------------------------------- | ------------------------------------------------------------ |
| Topology          | Group plus a private DM per user          | Ambient capture where the conversation already happens       |
| Clarification     | DM only, never the group                  | A question in the group derails a live human conversation    |
| DM visibility     | Private by default; promote on request    | A private channel that leaks silently is worse than none     |
| Nudge routing     | Owner's DM; group when both are involved  | Keeps the shared room quiet and the daily cap effective      |
| Transport         | Baileys linked device                     | Reads existing groups; no Official Business Account gate     |
| Build target      | Standalone service                        | Full control; avoids coupling to OpenClaw's release cycle    |
| Storage           | Relational tables, own schema             | Structured triggers now; semantic recall in Phase 2          |
| Database          | The bot's own database on aorus4          | Colocated with the voice stack; no shared schema             |
| Write path        | Direct Postgres                           | The guard and the write commit in one transaction            |
| Extraction model  | Ollama local, cloud override in config    | The data describes people who never consented to a cloud API |
| Resolution policy | Cautious, with a decisions log            | False merges cost far more than false splits                 |
| Outbound          | Drafts only                               | An extraction bug must not reach a third party               |
| Repository        | New standalone repo                       | Clean boundary and independent deploy                        |

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

The bot holds no relationship state. Postgres holds everything durable; the bot
keeps only its Baileys credentials on disk. A voice service therefore becomes a
second reader of the same tables rather than an integration project.

Module boundaries stay strict. `transport` knows nothing about relationships.
`extract` never touches the database. `store` alone performs I/O, behind a
repository interface, so swapping the write path later touches one module.

## Data model

Migration `009_add_relationships.sql`. Additive only; no existing table changes
shape.

```sql
people (
  id, user_id,                    -- who owns this relationship
  canonical_name, aliases TEXT[],
  phone, email, company, role, relationship_type,
  birthday DATE, timezone, comm_preference,
  first_met_at, first_met_context,
  last_interaction_at, next_nudge_at, cadence_days,
  embedding VECTOR(768),
  status, metadata JSONB, created_at, updated_at
)

interactions (
  id, person_id, occurred_at, channel,
  summary, raw_excerpt, captured_by,
  thought_id,                     -- narrative memory
  status, created_at
)

triggers (
  id, person_id, owner_user_id,
  kind,        -- birthday | followup | commitment | reconnect | context
  due_at, reason, payload JSONB,
  status,      -- pending | sent | approved | dismissed | snoozed
  sent_at, resolved_at
)

thought_people (thought_id, person_id, role)

resolution_log (
  id, candidate_name, chosen_person_id, score,
  action,      -- auto_match | asked | created
  confirmed_person_id, created_at
)

clarifications (
  id, asked_user_id, kind,   -- identity | ownership | fact | viewpoint
  question, context JSONB,
  status,                    -- pending | answered | expired
  answer, answered_at, created_at
)

-- additive, defaulted, safe for existing rows
memories (
  id, content, user_id, category, source,
  confidence, trust_weight, verified_at, expires_at,
  singleton_key UNIQUE,          -- auto-replace: employers and plans change
  visibility,                    -- 'shared' | 'private'
  status, metadata, created_at, updated_at
)

write_ops (op_id PRIMARY KEY, kind, result_id, created_at)
```

Four choices carry weight:

**Commitments live in `triggers` under `kind='commitment'`.** They share every
field and the whole delivery path. A separate table would duplicate structure to
preserve a distinction that exists only in prose.

**`thought_people` is a join table.** "Sarah introduced me to Marcus" is one
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

**`write_ops` is an idempotency ledger, claimed in the same transaction as the
write it guards.** Over HTTP the two could not be atomic: a crash between "insert
row" and "record op_id" left the write done and unrecorded, so the queue's replay
duplicated it. Direct Postgres closes that window.

`people.embedding` answers the question SQL cannot: who among our contacts would
care about this launch.

## Pipelines

### Capture

Group message → normalize → buffer → debounce 90 seconds or explicit
`@bot remember` → relevance gate → extraction → resolution → store → 📌 reaction.

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

Resolution scores each candidate against known people using alias matches,
phone and email matches, embedding similarity over context, and co-occurrence
with people already present in the conversation. Three outcomes follow:

```
score ≥ high         → match existing person
low < score < high   → ask in the group, park as pending_resolution
score ≤ low          → create a new person
```

Start cautious: set the bands so uncertain cases produce questions. Write every
decision to `resolution_log` with its score and the outcome the user confirmed.
Tune the bands from that data after several weeks rather than from guesswork.

The asymmetry drives the policy. A false merge fuses two histories silently and
forces an audit of every attached memory to unwind. A false split produces two
records that merge in seconds.

`resolve` returns a decision. It never writes.

### Clarification

Uncertain resolutions, ambiguous ownership, and low-confidence extractions
enqueue a clarification instead of a guess. The bot delivers it by DM to one
user, never to the group.

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
then composes. Five kinds fire: `birthday`, `reconnect` when cadence elapses,
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

| Failure                | Response                                           |
| ---------------------- | -------------------------------------------------- |
| Credential corruption  | Atomic write, `.bak` restore                       |
| Connection loss        | Dual-signal watchdog, exponential backoff          |
| OpenBrain unreachable  | On-disk write-ahead queue, replay on recovery      |
| Extraction failure     | Persist raw batch as `status='unextracted'`, retry |
| Malformed model output | Validate against schema, retry once, then park raw |
| Ambiguous identity     | Park as `pending_resolution` and ask               |

The write-ahead queue earns its complexity. Without it a thirty-second network
blip eats a memory and leaves no trace of what vanished.

Nothing fails silently. Every dropped path writes a durable row.

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
through `/export`. Colocating on the same Postgres server keeps a future IVR
able to join across databases without sharing a schema.

**Third-party data lands in a durable store.** People discussed in the group
acquire durable records they never consented to. Deletion by person must work
from day one, and `expires_at` should carry a default for low-confidence
extractions.

## Testing

- `transport`: mock the Baileys event emitter; no live WhatsApp in CI
- `extract`: golden fixtures pairing real transcripts against expected output
- `resolve`: table-driven cases covering the ambiguous band
- `store`: contract tests against a stubbed FastAPI
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
2. **Create the bot's database on aorus4.** `CREATE DATABASE prmm` with a role
   the bot owns, then apply `migrations/001_init.sql`. No pgvector needed:
   Phase 1 resolves identity by string, so nothing writes an embedding. The
   extension arrives with Phase 2's semantic person search.
3. **Verify Ollama** serves `jina/jina-embeddings-v2-base-en` and a model
   capable of structured extraction on the target host.
4. **Rotate the leaked MySQL root credential** found in plaintext in Claude Code
   session transcripts under `~/.claude/projects/`.

## Future: IVR

The voice platform reads the same tables. `people.phone` supports caller
identification, and `people.embedding` supports "who am I about to talk to."
Nothing in this design blocks that path, provided relationship state stays in
Postgres and out of the bot.

## Open questions

- Does the group need a `/people` command for browsing, or does Claude Code
  querying OpenBrain suffice?
- Should low-confidence extractions expire automatically, and after how long?
- How long should an unanswered clarification live before it expires?
- Should a user be able to read their own private rows back through search, or
  only correct them at the moment the bot asks?
- Do both users receive every nudge, or only the trigger's owner?
