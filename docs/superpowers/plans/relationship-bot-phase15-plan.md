# Phase 1.5 Implementation Plan — Observable and Answerable

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the bot's tables beside 1,738 existing contacts, start recording the two participants, and make every capture visibly acknowledged and every relational question answerable in the group.

**Architecture:** The `prmm` tables move into a dedicated schema inside the live `voice` database on aorus4, so `people` can join `public.person_contacts` without ever writing to it. `routeMessage` gains a fourth outcome — `question` — that diverts `@bot` mentions away from the capture buffer into a query module answering four intents with plain SQL. A reaction on the source message closes the feedback loop.

**Tech Stack:** Node 22+, TypeScript strict, pnpm, vitest, postgres.js, Baileys 7.0.0-rc13, Ollama `llama3.3:70b`.

## Global Constraints

- **Never write to `public.person_contacts`.** It belongs to a live platform. The bot reads it and points at it via `person_contact_id`.
- **All new tables live in the `prmm` schema**, never `public`. The voice database has ~60 tables and is still growing.
- **Migrations are ours**, numbered in `migrations/`, never entered into their `schema_migrations`.
- **TypeScript strict. No `any`, no `@ts-ignore`.** `pnpm test` runs `tsc --noEmit` first.
- **Visibility is enforced on every read path.** A question from one user must never surface the other's `private` rows.
- **A failed acknowledgement must never fail a committed capture.** Reactions are best-effort.
- **Integration tests run against the real `voice` database.** The last three defects in this project — BIGINT-as-string, the creds `.tmp` race, `@lid` senders — were all invisible to mocks.
- Repo: `~/Documents/Projects/prmm-bot`, deployed on macstudio, database on aorus4.

---

## File structure

| File                              | Responsibility                                                     |
| --------------------------------- | ------------------------------------------------------------------ |
| `migrations/002_voice_schema.sql` | Create `prmm` schema, add `person_contact_id` and `is_participant` |
| `src/config.ts`                   | Gains participant display names                                    |
| `src/types.ts`                    | `InboundMessage` carries the Baileys message key                   |
| `src/transport/normalize.ts`      | Preserve the key for reactions                                     |
| `src/transport/router.ts`         | Fourth route: `question`                                           |
| `src/transport/session.ts`        | `react()` alongside `sendText()`                                   |
| `src/store/pg-repository.ts`      | `findPeople` joins `person_contacts`; participant seeding          |
| `src/query/intent.ts`             | Parse a question into an intent (pure)                             |
| `src/query/answer.ts`             | Execute an intent, render an answer                                |
| `src/extract/prompt.ts`           | Participant roster; inverted participant rule                      |
| `src/index.ts`                    | Wire reactions and the question path                               |

---

### Task 1: Move to the voice database

**Files:**

- Create: `migrations/002_voice_schema.sql`
- Modify: `tests/migration.test.ts`

**Interfaces:**

- Consumes: `migrations/001_init.sql` table definitions
- Produces: schema `prmm` containing all eight tables; columns `prmm.people.person_contact_id TEXT`, `prmm.people.is_participant BOOLEAN`

- [ ] **Step 1: Write the migration**

```sql
-- 002_voice_schema.sql — install into the live `voice` database.
--
-- A dedicated schema, not `public`: that namespace holds ~60 tables owned by the
-- voice platform and still growing, so every future table either project adds is
-- a collision risk. `DROP SCHEMA prmm CASCADE` uninstalls this cleanly.

CREATE SCHEMA IF NOT EXISTS prmm;

-- Link, never write. `person_contacts` is read by a live platform; a bad
-- extraction writing into it would corrupt another system's production data.
ALTER TABLE prmm.people
  ADD COLUMN IF NOT EXISTS person_contact_id TEXT
    REFERENCES public.person_contacts(person_id) ON DELETE SET NULL;

-- The two humans in the group become subjects, so questions about each other
-- have an answer. Phase 1 deliberately refused this; Phase 1.5 reverses it.
ALTER TABLE prmm.people
  ADD COLUMN IF NOT EXISTS is_participant BOOLEAN NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS people_contact_idx
  ON prmm.people(person_contact_id) WHERE person_contact_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS people_participant_idx
  ON prmm.people(is_participant) WHERE is_participant;
```

- [ ] **Step 2: Write the guard test**

Append to `tests/migration.test.ts`:

```ts
const phase15 = readFileSync("migrations/002_voice_schema.sql", "utf8");

describe("migration 002", () => {
  it("creates a dedicated schema rather than using public", () => {
    expect(phase15).toMatch(/CREATE SCHEMA IF NOT EXISTS prmm/);
    expect(phase15).not.toMatch(/CREATE TABLE (IF NOT EXISTS )?public\./);
  });

  it("never writes to person_contacts", () => {
    // It belongs to a live platform. Reference only.
    expect(phase15).not.toMatch(/INSERT INTO public\.person_contacts/i);
    expect(phase15).not.toMatch(/UPDATE public\.person_contacts/i);
    expect(phase15).toMatch(/REFERENCES public\.person_contacts/);
  });

  it("is additive and re-runnable", () => {
    expect(phase15).not.toMatch(/DROP\s+(TABLE|COLUMN|SCHEMA)/i);
    expect(phase15.match(/ADD COLUMN(?! IF NOT EXISTS)/g)).toBeNull();
  });

  it("sets is_participant false by default so existing rows are unaffected", () => {
    expect(phase15).toMatch(/is_participant BOOLEAN NOT NULL DEFAULT false/);
  });
});
```

- [ ] **Step 3: Run the tests**

Run: `pnpm test`
Expected: PASS — 4 new tests in `tests/migration.test.ts`

- [ ] **Step 4: Apply to the voice database**

`001_init.sql` created tables in `public` of the old `prmm` database. Install both, in order, into `voice` under the new schema:

```bash
ssh aorus4 'docker exec -i realtime-ivr-db psql -U voice -d voice -v ON_ERROR_STOP=1 -c "CREATE SCHEMA IF NOT EXISTS prmm;"'
sed 's/CREATE TABLE IF NOT EXISTS /CREATE TABLE IF NOT EXISTS prmm./; s/REFERENCES people/REFERENCES prmm.people/; s/REFERENCES memories/REFERENCES prmm.memories/; s/ON people(/ON prmm.people(/; s/ON memories(/ON prmm.memories(/; s/ON interactions(/ON prmm.interactions(/; s/ON triggers(/ON prmm.triggers(/; s/ON clarifications(/ON prmm.clarifications(/; s/ON write_ops(/ON prmm.write_ops(/' \
  migrations/001_init.sql > /tmp/001_prmm.sql
scp /tmp/001_prmm.sql aorus4:/tmp/
ssh aorus4 'docker exec -i realtime-ivr-db psql -U voice -d voice -v ON_ERROR_STOP=1 -f - < /tmp/001_prmm.sql'
scp migrations/002_voice_schema.sql aorus4:/tmp/
ssh aorus4 'docker exec -i realtime-ivr-db psql -U voice -d voice -v ON_ERROR_STOP=1 -f - < /tmp/002_voice_schema.sql'
ssh aorus4 'docker exec realtime-ivr-db psql -U voice -d voice -Atc "SELECT tablename FROM pg_tables WHERE schemaname = '"'"'prmm'"'"' ORDER BY 1;"'
```

Expected: eight table names — `clarifications, interactions, memories, memory_people, people, resolution_log, triggers, write_ops`.

- [ ] **Step 5: Repoint the bot and verify**

The connection string changes database and adds a `search_path` so unqualified names resolve to `prmm` while `person_contacts` stays reachable in `public`.

On macstudio, edit `.env`:

```
PRMM_DATABASE_URL=postgres://voice:PASSWORD@192.168.1.246:5433/voice?options=-csearch_path%3Dprmm,public
```

The voice database password is in aorus4's existing compose environment; do not print it.

```bash
ssh macstudio 'cd ~/Documents/Projects/prmm-bot && node --dns-result-order=ipv4first --env-file=.env --import tsx -e "
import postgres from \"postgres\";
const sql = postgres(process.env.PRMM_DATABASE_URL);
console.log(await sql\`SELECT count(*)::int AS contacts FROM person_contacts\`);
console.log(await sql\`SELECT count(*)::int AS people FROM people\`);
await sql.end();"'
```

Expected: `contacts: 1738`, `people: 0`. Both names resolving proves the search_path is right.

- [ ] **Step 6: Tear down the old container**

Only after Step 5 passes. It holds zero rows.

```bash
ssh aorus4 'docker rm -f prmm-db && docker volume rm prmm-db-data'
```

- [ ] **Step 7: Commit**

```bash
git add migrations/002_voice_schema.sql tests/migration.test.ts
git commit -m "feat: install prmm schema into the voice database"
```

---

### Task 2: Resolve against person_contacts

**Files:**

- Modify: `src/store/pg-repository.ts`
- Test: `tests/pg-integration.test.ts` (create)

**Interfaces:**

- Consumes: `KnownPerson` from `src/resolve/score.ts`
- Produces: `findPeople(userId, includePrivate)` returning bot people **and** contacts; `KnownPerson.personContactId: string | null`

- [ ] **Step 1: Widen KnownPerson**

In `src/resolve/score.ts`, add to the interface:

```ts
export interface KnownPerson {
  id: number;
  canonicalName: string;
  aliases: string[];
  company: string | null;
  phone: string | null;
  email: string | null;
  /** Set when this candidate came from `person_contacts` rather than `people`. */
  personContactId: string | null;
}
```

- [ ] **Step 2: Write the failing integration test**

`tests/pg-integration.test.ts`:

```ts
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import postgres from "postgres";
import { PgRepository } from "../src/store/pg-repository.js";

// Integration only. Skipped without a database, because the last three defects
// in this project were all invisible to mocks.
const url = process.env.PRMM_DATABASE_URL;
const maybe = url ? describe : describe.skip;

maybe("PgRepository against the voice database", () => {
  const sql = postgres(url!, { max: 2 });
  const repo = new PgRepository(sql);

  beforeAll(async () => {
    await sql`INSERT INTO public.person_contacts (person_id, phone, first_name, last_name, company_name)
              VALUES ('itest-1', '+15550001111', 'Testina', 'Contact', 'Testco')
              ON CONFLICT (person_id) DO NOTHING`;
  });

  afterAll(async () => {
    await sql`DELETE FROM public.person_contacts WHERE person_id = 'itest-1'`;
    await sql.end();
  });

  it("returns existing contacts as resolution candidates", async () => {
    const people = await repo.findPeople(1, false);
    const found = people.find((p) => p.canonicalName === "Testina Contact");
    expect(found).toBeDefined();
    expect(found?.personContactId).toBe("itest-1");
    expect(found?.company).toBe("Testco");
  });

  it("returns at least the full contact book", async () => {
    // 1,738 real contacts plus the fixture. Resolution starts from these.
    expect((await repo.findPeople(1, false)).length).toBeGreaterThan(1000);
  });
});
```

- [ ] **Step 3: Run it and watch it fail**

Run: `PRMM_DATABASE_URL=<voice url> pnpm vitest run tests/pg-integration.test.ts`
Expected: FAIL — `personContactId` is undefined; contacts are not returned.

- [ ] **Step 4: Union contacts into findPeople**

Replace `findPeople` in `src/store/pg-repository.ts`:

```ts
  /**
   * Bot-known people, plus every contact from `person_contacts`.
   *
   * The contact book is 1,738 rows with company, title, email and phone — all
   * of which discriminate between people who share a first name. Resolving
   * against an empty table was the Phase 1 behaviour and it created a duplicate
   * for everyone already known.
   *
   * Contacts already linked to a `people` row are excluded, so a person never
   * appears twice.
   */
  async findPeople(
    userId: number,
    includePrivate: boolean,
  ): Promise<KnownPerson[]> {
    const rows = await this.sql<PersonRow[]>`
      SELECT id::text AS id, canonical_name, aliases, company, phone, email,
             person_contact_id
      FROM prmm.people
      WHERE status = 'active'
        AND (visibility = 'shared'
             OR (${includePrivate} AND visibility = 'private' AND user_id = ${userId}))

      UNION ALL

      SELECT NULL AS id,
             trim(pc.first_name || ' ' || pc.last_name) AS canonical_name,
             ARRAY[]::text[] AS aliases,
             NULLIF(pc.company_name, '') AS company,
             NULLIF(pc.phone, '') AS phone,
             NULLIF(pc.email, '') AS email,
             pc.person_id AS person_contact_id
      FROM public.person_contacts pc
      WHERE trim(pc.first_name || ' ' || pc.last_name) <> ''
        AND NOT EXISTS (
          SELECT 1 FROM prmm.people p WHERE p.person_contact_id = pc.person_id
        )
    `;

    return rows.map((row) => ({
      id: row.id === null ? 0 : toId(row.id),
      canonicalName: row.canonical_name,
      aliases: row.aliases ?? [],
      company: row.company,
      phone: row.phone,
      email: row.email,
      personContactId: row.person_contact_id,
    }));
  }
```

Update `PersonRow`:

```ts
interface PersonRow {
  id: string | null;
  canonical_name: string;
  aliases: string[] | null;
  company: string | null;
  phone: string | null;
  email: string | null;
  person_contact_id: string | null;
}
```

- [ ] **Step 5: Run the integration test**

Run: `PRMM_DATABASE_URL=<voice url> pnpm vitest run tests/pg-integration.test.ts`
Expected: PASS — 2 tests

- [ ] **Step 6: Carry the link through creation**

A candidate matched from `person_contacts` has `id === 0` and no `people` row. `upsertPerson` must store the link. In `src/store/repository.ts`, add to `UpsertPersonInput`:

```ts
/** Set when this person was matched from the contact book. */
personContactId: string | null;
```

In `pg-repository.ts`, both branches of the upsert gain the column:

```ts
              INSERT INTO prmm.people (user_id, canonical_name, aliases, company,
                                       first_met_context, visibility, person_contact_id)
              VALUES (${input.userId}, ${input.canonicalName}, ${input.aliases},
                      ${input.company}, ${input.firstMetContext}, 'shared',
                      ${input.personContactId})
```

(the private branch is identical but for `'private'`).

- [ ] **Step 7: Run the full suite and commit**

Existing pipeline tests will fail to typecheck until `personContactId` is added to their fixtures — add `personContactId: null` to every `KnownPerson` and `upsertPerson` literal in `tests/pipeline.test.ts`, `tests/resolve.test.ts`, and `tests/queue.test.ts`.

Run: `pnpm test`
Expected: PASS

```bash
git add src tests
git commit -m "feat: resolve identity against the 1,738-contact book"
```

---

### Task 3: Record the participants

**Files:**

- Modify: `src/config.ts`, `src/extract/prompt.ts`, `src/pipeline.ts`
- Modify: `evals/fixtures/05-participant-not-a-person.json`
- Create: `evals/fixtures/06-bare-number-is-not-a-person.json`

**Interfaces:**

- Consumes: `Config.users`
- Produces: `UserBinding.displayName: string`; `buildPrompt(batch, roster)` where `roster: {e164: string, name: string}[]`

- [ ] **Step 1: Add display names to config**

In `src/config.ts`, extend the schema and binding:

```ts
  PRMM_USER_A_NAME: z.string().min(1),
  PRMM_USER_B_NAME: z.string().min(1),
```

```ts
const users: UserBinding[] = [
  {
    userId: e.PRMM_USER_A_ID,
    e164: e.PRMM_USER_A_E164,
    dmJid: e.PRMM_USER_A_DM_JID,
    displayName: e.PRMM_USER_A_NAME,
  },
  {
    userId: e.PRMM_USER_B_ID,
    e164: e.PRMM_USER_B_E164,
    dmJid: e.PRMM_USER_B_DM_JID,
    displayName: e.PRMM_USER_B_NAME,
  },
];
```

And in `src/types.ts`:

```ts
export interface UserBinding {
  userId: number;
  e164: string;
  dmJid: string;
  /** Shown to the extractor so it can attribute a memory to a participant. */
  displayName: string;
}
```

Add to `.env.example`:

```
PRMM_USER_A_NAME=Joel
PRMM_USER_B_NAME=Jo
```

- [ ] **Step 2: Write the failing prompt test**

`tests/prompt.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { buildPrompt, SYSTEM_PROMPT } from "../src/extract/prompt.js";
import type { CaptureBatch } from "../src/capture/buffer.js";

const batch: CaptureBatch = {
  route: { kind: "group", userId: 1 },
  participants: [1],
  closedAt: new Date("2026-07-26T12:00:00Z"),
  messages: [
    {
      id: "m1",
      chatJid: "g@g.us",
      senderJid: "s@s.whatsapp.net",
      senderE164: "+15550001111",
      text: "Jo and I met at the hacker house",
      timestamp: new Date("2026-07-26T12:00:00Z"),
      key: {},
    },
  ],
};

const roster = [
  { e164: "+15550001111", name: "Joel" },
  { e164: "+15550002222", name: "Jo" },
];

describe("buildPrompt", () => {
  it("names the participants so the model can attribute to them", () => {
    // Without this the transcript is phone numbers and the model cannot know
    // who "I" is, so a memory about a participant is unattributable.
    const prompt = buildPrompt(batch, roster);
    expect(prompt).toContain("Joel");
    expect(prompt).toContain("Jo");
    expect(prompt).toContain("+15550001111");
  });
});

describe("SYSTEM_PROMPT", () => {
  it("instructs the model to record participants by name", () => {
    expect(SYSTEM_PROMPT).toMatch(
      /participants.*by name|record the participants/i,
    );
  });

  it("still forbids inventing a person from a bare number", () => {
    expect(SYSTEM_PROMPT).toMatch(
      /never.*phone number.*person|bare phone number/i,
    );
  });
});
```

- [ ] **Step 3: Run and watch it fail**

Run: `pnpm vitest run tests/prompt.test.ts`
Expected: FAIL — `buildPrompt` takes one argument.

- [ ] **Step 4: Rewrite the prompt module**

Replace `src/extract/prompt.ts`:

```ts
import type { CaptureBatch } from "../capture/buffer.js";

export interface RosterEntry {
  e164: string;
  name: string;
}

export const SYSTEM_PROMPT = `You extract relationship facts from chat transcripts.
Return ONLY JSON matching this shape:
{"people":[{"name":"","aliases":[],"company":null,"context":"","confidence":0.0}],
 "memories":[{"about":"","content":"","category":"relationship","confidence":0.0}],
 "commitments":[{"owner":"","what":"","due":null,"confidence":0.0}],
 "dates":[{"person":"","kind":"other","date":"","confidence":0.0}]}
Rules:
- The transcript header names each speaker. Record the participants themselves by
  name when they are discussed, exactly as you would any other person.
- Never turn a bare phone number into a person. If a speaker has no name in the
  header, do not invent one.
- "about" in memories MUST exactly match a "name" in people.
- confidence is 0.0-1.0. Use below 0.5 when you are guessing.
- Omit anything you did not read in the transcript. Never invent a detail.
- Use empty arrays when nothing applies.`;

export function buildPrompt(
  batch: CaptureBatch,
  roster: RosterEntry[],
): string {
  const header = roster.map((r) => `${r.e164} is ${r.name}`).join("\n");
  const byNumber = new Map(roster.map((r) => [r.e164, r.name]));
  const lines = batch.messages
    .map((m) => {
      const who = m.senderE164
        ? (byNumber.get(m.senderE164) ?? m.senderE164)
        : "unknown-sender";
      return `${who}: ${m.text}`;
    })
    .join("\n");
  return `Speakers:\n${header}\n\nTranscript (${batch.closedAt.toISOString()}):\n${lines}`;
}
```

- [ ] **Step 5: Thread the roster through the extractor**

In `src/extract/extractor.ts`, `ChatExtractor.extract` builds the prompt, so the roster must reach it. Add a constructor field to both extractors:

```ts
abstract class ChatExtractor implements Extractor {
  protected abstract complete(prompt: string): Promise<string>;
  protected abstract roster(): RosterEntry[];

  async extract(batch: CaptureBatch): Promise<ExtractionResult> {
    const prompt = buildPrompt(batch, this.roster());
    // ... unchanged retry loop
```

`OllamaExtractor` and `OpenAiCompatExtractor` each take `private readonly people: RosterEntry[]` as a final constructor argument and implement `protected roster() { return this.people; }`.

In `src/index.ts`:

```ts
const roster = cfg.users.map((u) => ({ e164: u.e164, name: u.displayName }));
const extractor = new OllamaExtractor(cfg.ollamaUrl, cfg.ollamaModel, roster);
```

In `src/eval/run.ts`, pass a fixed roster so evals stay reproducible:

```ts
const EVAL_ROSTER = [
  { e164: "+15555550100", name: "Joel" },
  { e164: "+15555550101", name: "Jo" },
];
```

- [ ] **Step 6: Rewrite the participant fixture**

Replace `evals/fixtures/05-participant-not-a-person.json`:

```json
{
  "name": "participant-is-a-person",
  "note": "Phase 1.5 reverses Phase 1: a named participant IS recorded. This fixture asserted the opposite and is inverted deliberately.",
  "messages": [
    {
      "from": "+15555550100",
      "text": "Jo and I met at the hacker house in 2019"
    },
    { "from": "+15555550101", "text": "feels like longer than that" }
  ],
  "expected": {
    "people": [
      {
        "name": "Jo",
        "aliases": [],
        "company": null,
        "context": "met at the hacker house in 2019",
        "confidence": 0.85
      }
    ],
    "memories": [
      {
        "about": "Jo",
        "content": "met at the hacker house in 2019",
        "category": "relationship",
        "confidence": 0.85
      }
    ],
    "commitments": [],
    "dates": []
  }
}
```

Create `evals/fixtures/06-bare-number-is-not-a-person.json`:

```json
{
  "name": "bare-number-is-not-a-person",
  "note": "The protection that survives from Phase 1: a speaker with no name in the header must never become a person row.",
  "messages": [
    { "from": "+19998887777", "text": "call me back when you get a chance" }
  ],
  "expected": { "people": [], "memories": [], "commitments": [], "dates": [] }
}
```

- [ ] **Step 7: Run the tests and the eval**

Run: `pnpm test`
Expected: PASS

Run on macstudio: `pnpm eval`
Expected: 6/6 fixtures, 0 invented people. The roster in `run.ts` must include `+19998887777` in _no_ entry, so fixture 06 has an unnamed speaker.

- [ ] **Step 8: Seed the participants**

```bash
ssh aorus4 'docker exec realtime-ivr-db psql -U voice -d voice -v ON_ERROR_STOP=1 -c "
INSERT INTO prmm.people (user_id, canonical_name, visibility, is_participant)
VALUES (1, '"'"'Joel'"'"', '"'"'shared'"'"', true),
       (2, '"'"'Jo'"'"',   '"'"'shared'"'"', true)
ON CONFLICT DO NOTHING;"'
```

Expected: `INSERT 0 2`. Both are `shared` — the participants are known to each other by definition.

- [ ] **Step 9: Commit**

```bash
git add src tests evals .env.example
git commit -m "feat: record the participants as people"
```

---

### Task 4: Acknowledge every capture

**Files:**

- Modify: `src/types.ts`, `src/transport/normalize.ts`, `src/transport/session.ts`, `src/index.ts`
- Test: `tests/router.test.ts`, `tests/session.test.ts`

**Interfaces:**

- Consumes: `CaptureOutcome.status` from `src/pipeline.ts`
- Produces: `InboundMessage.key: MessageKeyLike`; `WhatsAppSession.react(key, emoji): Promise<void>`

- [ ] **Step 1: Write the failing test**

Append to `tests/router.test.ts`:

```ts
it("preserves the Baileys key so a reaction can target the message", () => {
  // Reactions address a message by its full key; id alone is not enough.
  const out = normalizeMessage({
    key: {
      id: "A10",
      remoteJid: "123@g.us",
      participant: "15555550100@s.whatsapp.net",
    },
    message: { conversation: "met Sarah Chen" },
    messageTimestamp: 1785000000,
  });
  expect(out?.key).toEqual(
    expect.objectContaining({ id: "A10", remoteJid: "123@g.us" }),
  );
});
```

Append to `tests/session.test.ts`:

```ts
it("sends a reaction addressed to the original message", async () => {
  const sock = fakeSocket();
  const session = Object.assign(Object.create(WhatsAppSession.prototype), {
    sock,
  }) as WhatsAppSession;
  await session.react({ id: "A1", remoteJid: "123@g.us" }, "📌");
  expect(sock.sendMessage).toHaveBeenCalledWith("123@g.us", {
    react: { text: "📌", key: { id: "A1", remoteJid: "123@g.us" } },
  });
});
```

`tests/session.test.ts` needs `import { WhatsAppSession } from "../src/transport/session.js";`.

- [ ] **Step 2: Run and watch both fail**

Run: `pnpm vitest run tests/router.test.ts tests/session.test.ts`
Expected: FAIL — `key` is not on `InboundMessage`; `react` is not a function.

- [ ] **Step 3: Carry the key**

In `src/types.ts`:

```ts
/** Minimal Baileys message key — enough to address a reaction. */
export interface MessageKeyLike {
  id?: string | null;
  remoteJid?: string | null;
  participant?: string | null;
  fromMe?: boolean | null;
}

export interface InboundMessage {
  id: string;
  /** Full key, kept so the bot can react to this exact message. */
  key: MessageKeyLike;
  chatJid: string;
  senderJid: string;
  senderE164: string | null;
  text: string;
  timestamp: Date;
}
```

In `src/transport/normalize.ts`, add to the returned object:

```ts
    key: raw.key,
```

- [ ] **Step 4: Add react()**

In `src/transport/session.ts`, extend `SocketLike`:

```ts
  sendMessage(
    jid: string,
    content: { text: string } | { react: { text: string; key: MessageKeyLike } },
  ): Promise<unknown>;
```

and add the method:

```ts
  /**
   * React to a message. Best-effort by contract: a failed acknowledgement must
   * never fail a capture that already committed to the database.
   */
  async react(key: MessageKeyLike, emoji: string): Promise<void> {
    if (!this.sock || !key.remoteJid) return;
    await this.sock.sendMessage(key.remoteJid, { react: { text: emoji, key } });
  }
```

Import `MessageKeyLike` from `../types.js`.

- [ ] **Step 5: Run the tests**

Run: `pnpm vitest run tests/router.test.ts tests/session.test.ts`
Expected: PASS

- [ ] **Step 6: Wire acknowledgement**

In `src/index.ts`, the capture callback gains the source message. `CaptureBuffer` flushes a batch, so react to its **last** message — the one that closed the window:

```ts
const ACK: Record<string, string | null> = {
  stored: "📌",
  degraded: "⚠️",
  parked: null,
  skipped: null,
};

const capture = (batch: CaptureBatch, attempt = 0): Promise<void> =>
  runCapture(batch, {/* unchanged deps */})
    .then(async (out) => {
      console.log("capture", out);
      if (out.questions.length > 0) {
        console.warn(`pending clarifications: ${out.questions.join(", ")}`);
      }
      const emoji = out.questions.length > 0 ? "❓" : ACK[out.status];
      const last = batch.messages.at(-1);
      if (emoji && last) {
        // Best effort: never let a missing ack fail a committed capture.
        await session
          .react(last.key, emoji)
          .catch((e: unknown) => console.error("ack failed", e));
      }
    })
    .catch((error: unknown) => console.error("capture failed", error));
```

`session` is declared after `capture` today; move the `const session = new WhatsAppSession(...)` block above `capture`, and have the message handler call `buffer.add` as before.

- [ ] **Step 7: Verify live**

Restart the bot on macstudio and send a message naming a third party in the group.

Expected: a 📌 reaction appears on your message within ~2 minutes, and `capture { status: 'stored', ... }` is in `/tmp/prmm.out`.

- [ ] **Step 8: Commit**

```bash
git add src tests
git commit -m "feat: react to every capture so the bot is visibly alive"
```

---

### Task 5: Route mentions as questions

**Files:**

- Modify: `src/config.ts`, `src/transport/router.ts`, `src/index.ts`
- Test: `tests/router.test.ts`

**Interfaces:**

- Consumes: `Config`
- Produces: `Route` gains `{ kind: "question"; userId: number; text: string }`

- [ ] **Step 1: Write the failing test**

Append to `tests/router.test.ts`:

```ts
describe("mention gating", () => {
  it("routes a mention as a question, never as capture", () => {
    // Without this the mention itself is extracted and the bot's own name
    // becomes a contact.
    const m = msg("123@g.us", "+15555550100");
    m.text = "@calvin where did I meet Jo?";
    const route = routeMessage(m, cfg);
    expect(route.kind).toBe("question");
    if (route.kind === "question") {
      expect(route.userId).toBe(1);
      expect(route.text).toBe("where did I meet Jo?");
    }
  });

  it("is case-insensitive and tolerates no leading @", () => {
    const m = msg("123@g.us", "+15555550100");
    m.text = "Calvin, what do I know about Marcus?";
    expect(routeMessage(m, cfg).kind).toBe("question");
  });

  it("does not treat a mid-sentence mention as a question", () => {
    // "I told calvin about it" is a statement worth capturing, not a query.
    const m = msg("123@g.us", "+15555550100");
    m.text = "I told calvin about the launch";
    expect(routeMessage(m, cfg).kind).toBe("group");
  });

  it("routes mentions in a DM too", () => {
    const m = msg("15555550101@s.whatsapp.net", "+15555550101");
    m.text = "@calvin who do I know at Initech?";
    const route = routeMessage(m, cfg);
    expect(route.kind).toBe("question");
    if (route.kind === "question") expect(route.userId).toBe(2);
  });
});
```

The `msg` helper returns a frozen literal today; change its return type to a mutable `InboundMessage` and add `key: {}` to the object.

- [ ] **Step 2: Run and watch it fail**

Run: `pnpm vitest run tests/router.test.ts`
Expected: FAIL — no `question` kind.

- [ ] **Step 3: Add the bot name to config**

In `src/config.ts` schema and Config:

```ts
  PRMM_BOT_NAME: z.string().min(1).default("calvin"),
```

```ts
/** Name the bot answers to. Matched at the start of a message only. */
botName: string;
```

```ts
    botName: e.PRMM_BOT_NAME.toLowerCase(),
```

`.env.example`: `PRMM_BOT_NAME=calvin`

- [ ] **Step 4: Extend the router**

In `src/transport/router.ts`:

```ts
export type Route =
  | { kind: "group"; userId: number }
  | { kind: "dm"; userId: number }
  | { kind: "question"; userId: number; text: string }
  | { kind: "ignore"; reason: IgnoreReason };
```

Add above `routeMessage`:

```ts
/**
 * A message is a question only when it *opens* by addressing the bot.
 *
 * "I told calvin about the launch" is a statement worth capturing; treating any
 * occurrence as a query would swallow ordinary conversation.
 */
function asQuestion(text: string, botName: string): string | null {
  const match = new RegExp(`^\\s*@?${botName}\\b[\\s,:]*`, "i").exec(text);
  if (!match) return null;
  const rest = text.slice(match[0].length).trim();
  return rest.length > 0 ? rest : null;
}
```

and in `routeMessage`, after the sender is resolved and before the group branch:

```ts
const onOurChat =
  msg.chatJid === cfg.groupJid ||
  cfg.users.some((u) => u.dmJid === msg.chatJid);

if (sender && onOurChat) {
  const question = asQuestion(msg.text, cfg.botName);
  if (question !== null) {
    return { kind: "question", userId: sender.userId, text: question };
  }
}
```

- [ ] **Step 5: Run the tests**

Run: `pnpm vitest run tests/router.test.ts`
Expected: PASS — 4 new tests

- [ ] **Step 6: Handle the new route in index.ts**

`buffer.add` rejects non-capture routes, so the question must be intercepted first:

```ts
if (route.kind === "question") {
  void track(
    answerQuestion(route.text, route.userId, { repo, sql })
      .then((reply) => session.sendText(message.chatJid, reply))
      .catch((error: unknown) => {
        console.error("answer failed", error);
        return session.sendText(
          message.chatJid,
          "Something went wrong looking that up.",
        );
      }),
  );
  return;
}
```

`answerQuestion` arrives in Task 6. Until then this will not compile — implement Task 6 before running the bot.

- [ ] **Step 7: Commit**

```bash
git add src tests .env.example
git commit -m "feat: gate mentions as questions instead of extracting them"
```

---

### Task 6: Answer the four questions

**Files:**

- Create: `src/query/intent.ts`, `src/query/answer.ts`
- Test: `tests/intent.test.ts`, `tests/answer.test.ts`

**Interfaces:**

- Consumes: `Repository`, `postgres.Sql`, `scoreCandidate`
- Produces: `parseIntent(text): Intent`; `answerQuestion(text, userId, deps): Promise<string>`

- [ ] **Step 1: Write the failing intent test**

`tests/intent.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { parseIntent } from "../src/query/intent.js";

describe("parseIntent", () => {
  it("recognises where-met", () => {
    expect(parseIntent("where did I meet Jo?")).toEqual({
      kind: "where-met",
      subject: "Jo",
    });
  });

  it("recognises last-spoke", () => {
    expect(parseIntent("when did I last talk to Sarah Chen")).toEqual({
      kind: "last-spoke",
      subject: "Sarah Chen",
    });
  });

  it("recognises what-known", () => {
    expect(parseIntent("what do I know about Marcus Webb?")).toEqual({
      kind: "what-known",
      subject: "Marcus Webb",
    });
  });

  it("recognises who-at-company", () => {
    expect(parseIntent("who do I know at Initech?")).toEqual({
      kind: "who-at",
      subject: "Initech",
    });
  });

  it("returns unknown for anything else", () => {
    // An honest refusal beats a wrong answer.
    expect(parseIntent("what is the weather")).toEqual({ kind: "unknown" });
  });

  it("strips trailing punctuation from the subject", () => {
    expect(parseIntent("where did I meet Jo!!")).toEqual({
      kind: "where-met",
      subject: "Jo",
    });
  });
});
```

- [ ] **Step 2: Run and watch it fail**

Run: `pnpm vitest run tests/intent.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the intent parser**

`src/query/intent.ts`:

```ts
export type Intent =
  | { kind: "where-met"; subject: string }
  | { kind: "last-spoke"; subject: string }
  | { kind: "what-known"; subject: string }
  | { kind: "who-at"; subject: string }
  | { kind: "unknown" };

/**
 * Pattern-matched, not model-inferred.
 *
 * These four questions are relational: each is one SQL query over a column that
 * already exists. Routing them through an LLM would add latency and a failure
 * mode for no gain. Fuzzy recall — "who might care about this launch" — needs
 * Phase 2 vectors and is deliberately absent here.
 */
const PATTERNS: { re: RegExp; kind: Intent["kind"] }[] = [
  {
    re: /where\s+(?:did|do)\s+(?:i|we)\s+(?:first\s+)?meet\s+(.+)/i,
    kind: "where-met",
  },
  {
    re: /when\s+(?:did|do)\s+(?:i|we)\s+last\s+(?:talk|speak)\s+(?:to|with)\s+(.+)/i,
    kind: "last-spoke",
  },
  { re: /what\s+do\s+(?:i|we)\s+know\s+about\s+(.+)/i, kind: "what-known" },
  { re: /who\s+do\s+(?:i|we)\s+know\s+at\s+(.+)/i, kind: "who-at" },
];

export function parseIntent(text: string): Intent {
  for (const { re, kind } of PATTERNS) {
    const match = re.exec(text);
    const subject = match?.[1]?.replace(/[?!.,\s]+$/, "").trim();
    if (subject) return { kind, subject } as Intent;
  }
  return { kind: "unknown" };
}
```

- [ ] **Step 4: Run the intent tests**

Run: `pnpm vitest run tests/intent.test.ts`
Expected: PASS — 6 tests

- [ ] **Step 5: Write the failing answer test**

`tests/answer.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import { answerQuestion, type AnswerDeps } from "../src/query/answer.js";
import type { KnownPerson } from "../src/resolve/score.js";

const jo: KnownPerson = {
  id: 1,
  canonicalName: "Jo",
  aliases: [],
  company: null,
  phone: null,
  email: null,
  personContactId: null,
};

function deps(over: Partial<AnswerDeps> = {}): AnswerDeps {
  return {
    findPeople: vi.fn(async () => [jo]),
    whereMet: vi.fn(async () => "the hacker house in 2019"),
    lastSpoke: vi.fn(async () => new Date("2026-07-01T00:00:00Z")),
    memoriesAbout: vi.fn(async () => ["launch is in August"]),
    peopleAt: vi.fn(async () => ["Marcus Webb"]),
    ...over,
  };
}

describe("answerQuestion", () => {
  it("answers where-met from first_met_context", async () => {
    const reply = await answerQuestion("where did I meet Jo?", 1, deps());
    expect(reply).toContain("hacker house");
  });

  it("says so plainly when nothing is recorded", async () => {
    // An empty answer reads as a failure; naming the gap does not.
    const reply = await answerQuestion(
      "where did I meet Jo?",
      1,
      deps({ whereMet: vi.fn(async () => null) }),
    );
    expect(reply).toMatch(/don't have|no record/i);
    expect(reply).toContain("Jo");
  });

  it("asks rather than guessing when the subject is ambiguous", async () => {
    const two = [jo, { ...jo, id: 2, canonicalName: "Jo Nguyen" }];
    const reply = await answerQuestion(
      "where did I meet Jo?",
      1,
      deps({ findPeople: vi.fn(async () => two) }),
    );
    expect(reply).toMatch(/which/i);
  });

  it("names its own capabilities when the intent is unknown", async () => {
    const reply = await answerQuestion("what is the weather", 1, deps());
    expect(reply).toMatch(/where you met|last spoke|know about/i);
  });

  it("says nobody is known at a company with no matches", async () => {
    const reply = await answerQuestion(
      "who do I know at Initech?",
      1,
      deps({ peopleAt: vi.fn(async () => []) }),
    );
    expect(reply).toMatch(/nobody|no one/i);
  });
});
```

- [ ] **Step 6: Run and watch it fail**

Run: `pnpm vitest run tests/answer.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 7: Write the answer module**

`src/query/answer.ts`:

```ts
import { DEFAULT_BANDS, resolveIdentity } from "../resolve/resolver.js";
import { scoreCandidate, type KnownPerson } from "../resolve/score.js";
import { parseIntent } from "./intent.js";

export interface AnswerDeps {
  findPeople: (
    userId: number,
    includePrivate: boolean,
  ) => Promise<KnownPerson[]>;
  whereMet: (personId: number) => Promise<string | null>;
  lastSpoke: (personId: number) => Promise<Date | null>;
  memoriesAbout: (personId: number, userId: number) => Promise<string[]>;
  peopleAt: (company: string, userId: number) => Promise<string[]>;
}

const CAPABILITIES =
  "I can tell you where you met someone, when you last spoke to them, " +
  "what I know about them, or who you know at a company.";

/**
 * Resolve the subject with the same logic capture uses.
 *
 * Reusing `scoreCandidate` means "Sarah" is ambiguous in a question for exactly
 * the reasons it is ambiguous in a capture — and the answer says so instead of
 * silently picking one.
 */
async function subjectOf(
  name: string,
  userId: number,
  deps: AnswerDeps,
): Promise<{ person: KnownPerson } | { ambiguous: string[] } | null> {
  const known = await deps.findPeople(userId, true);
  const candidate = {
    name,
    aliases: [] as string[],
    company: null,
    context: "",
    confidence: 1,
  };
  const scored = scoreCandidate(candidate, known);
  const decision = resolveIdentity(scored, DEFAULT_BANDS);

  if (decision.action === "match") {
    const person = known.find((p) => p.id === decision.personId);
    return person ? { person } : null;
  }
  if (decision.action === "ask") {
    const names = decision.candidates
      .map((c) => known.find((p) => p.id === c.personId)?.canonicalName)
      .filter((n): n is string => Boolean(n));
    return names.length > 1 ? { ambiguous: names } : null;
  }
  return null;
}

export async function answerQuestion(
  text: string,
  userId: number,
  deps: AnswerDeps,
): Promise<string> {
  const intent = parseIntent(text);
  if (intent.kind === "unknown") {
    return `I can't answer that yet. ${CAPABILITIES}`;
  }

  if (intent.kind === "who-at") {
    const names = await deps.peopleAt(intent.subject, userId);
    return names.length === 0
      ? `Nobody I know of at ${intent.subject}.`
      : `At ${intent.subject}: ${names.join(", ")}.`;
  }

  const resolved = await subjectOf(intent.subject, userId, deps);
  if (resolved === null) {
    return `I don't have anyone called ${intent.subject}.`;
  }
  if ("ambiguous" in resolved) {
    return `Which ${intent.subject}? I know ${resolved.ambiguous.join(" and ")}.`;
  }

  const { person } = resolved;

  if (intent.kind === "where-met") {
    const where = await deps.whereMet(person.id);
    return where
      ? `You met ${person.canonicalName} ${where}.`
      : `I don't have a record of where you met ${person.canonicalName}.`;
  }

  if (intent.kind === "last-spoke") {
    const when = await deps.lastSpoke(person.id);
    return when
      ? `Last interaction with ${person.canonicalName} was ${when.toISOString().slice(0, 10)}.`
      : `No recorded interactions with ${person.canonicalName} yet.`;
  }

  const memories = await deps.memoriesAbout(person.id, userId);
  return memories.length === 0
    ? `I don't have anything recorded about ${person.canonicalName} yet.`
    : `About ${person.canonicalName}: ${memories.join("; ")}.`;
}
```

- [ ] **Step 8: Run the answer tests**

Run: `pnpm vitest run tests/answer.test.ts`
Expected: PASS — 5 tests

- [ ] **Step 9: Implement the queries**

Add to `src/store/pg-repository.ts`. Visibility is filtered on read, per the global constraint:

```ts
  async whereMet(personId: number): Promise<string | null> {
    const [row] = await this.sql<{ ctx: string | null }[]>`
      SELECT COALESCE(NULLIF(p.first_met_context, ''), pc.contact_source) AS ctx
      FROM prmm.people p
      LEFT JOIN public.person_contacts pc ON pc.person_id = p.person_contact_id
      WHERE p.id = ${personId}
    `;
    return row?.ctx ?? null;
  }

  async lastSpoke(personId: number): Promise<Date | null> {
    const [row] = await this.sql<{ at: Date | null }[]>`
      SELECT max(occurred_at) AS at FROM prmm.interactions
      WHERE person_id = ${personId}
    `;
    return row?.at ?? null;
  }

  /** Shared memories, plus this user's own private ones. Never the other's. */
  async memoriesAbout(personId: number, userId: number): Promise<string[]> {
    const rows = await this.sql<{ content: string }[]>`
      SELECT m.content
      FROM prmm.memories m
      JOIN prmm.memory_people mp ON mp.memory_id = m.id
      WHERE mp.person_id = ${personId}
        AND m.status = 'active'
        AND (m.visibility = 'shared' OR m.user_id = ${userId})
      ORDER BY m.created_at DESC
      LIMIT 10
    `;
    return rows.map((r) => r.content);
  }

  async peopleAt(company: string, userId: number): Promise<string[]> {
    const rows = await this.sql<{ name: string }[]>`
      SELECT canonical_name AS name FROM prmm.people
      WHERE status = 'active' AND company ILIKE ${`%${company}%`}
        AND (visibility = 'shared' OR user_id = ${userId})
      UNION
      SELECT trim(first_name || ' ' || last_name) AS name
      FROM public.person_contacts
      WHERE company_name ILIKE ${`%${company}%`}
      LIMIT 20
    `;
    return rows.map((r) => r.name);
  }
```

Add all four to the `Repository` interface in `src/store/repository.ts`, and to the `repo()` fixtures in `tests/pipeline.test.ts` and `tests/queue.test.ts` as `vi.fn(async () => null)` / `vi.fn(async () => [])` so they still satisfy the type.

- [ ] **Step 10: Wire it in index.ts**

Replace the placeholder from Task 5 Step 6:

```ts
import { answerQuestion } from "./query/answer.js";
```

```ts
const answerDeps = {
  findPeople: (u: number, p: boolean) => repo.findPeople(u, p),
  whereMet: (id: number) => inner.whereMet(id),
  lastSpoke: (id: number) => inner.lastSpoke(id),
  memoriesAbout: (id: number, u: number) => inner.memoriesAbout(id, u),
  peopleAt: (c: string, u: number) => inner.peopleAt(c, u),
};
```

where `inner` is the `PgRepository` instance, hoisted out of the `QueuedRepository` construction:

```ts
const inner = new PgRepository(sql);
const repo = new QueuedRepository(inner, writeQueue, quarantine);
```

Then `answerQuestion(route.text, route.userId, answerDeps)`.

- [ ] **Step 11: Run everything**

Run: `pnpm test`
Expected: PASS

- [ ] **Step 12: Verify live**

Restart the bot on macstudio. In the group, send:

```
@calvin where did I meet Jo?
```

Expected: a reply within a few seconds, no 📌 (questions are not captures), and `/tmp/prmm.out` shows no `capture` line for that message.

Then send `@calvin what is for dinner` and expect the capability list.

- [ ] **Step 13: Commit**

```bash
git add src tests
git commit -m "feat: answer where-met, last-spoke, what-known and who-at"
```

---

### Task 7: Announce a private memory about the other participant

**Files:**
- Modify: `src/config.ts`, `src/pipeline.ts`, `src/index.ts`
- Test: `tests/pipeline.test.ts`

**Interfaces:**
- Consumes: `CaptureDeps`, `KnownPerson`
- Produces: `Config.allowPrivateAboutParticipant: boolean`; `CaptureDeps.participantUserIdFor: (personId: number) => number | undefined`; `CaptureOutcome.announcements: string[]`

Once the participants are subjects, a DM can hold a private memory *about the
other participant* — something one user tells the bot about the other, inside a
memory they otherwise share. The spec allows it and requires the bot to say so.
Storing it silently would make the private channel a trap.

- [ ] **Step 1: Write the failing test**

Append to `tests/pipeline.test.ts`:

```ts
describe("private memories about the other participant", () => {
  const joPerson = {
    id: 99, canonicalName: "Jo", aliases: [], company: null,
    phone: null, email: null, personContactId: null,
  };

  it("stores and announces who cannot see it", async () => {
    const r = repo({ findPeople: vi.fn(async () => [joPerson]) });
    const out = await runCapture(
      batch("Jo has been stressed about work", { kind: "dm", userId: 1 }, [1]),
      deps({
        repo: r,
        extractor: extractorOf({
          people: [person("Jo")],
          memories: [memory("Jo", "has been stressed about work", 0.9)],
        }),
        participantUserIdFor: (id) => (id === 99 ? 2 : undefined),
      }),
    );

    expect(r.captureMemory).toHaveBeenCalledWith(
      expect.objectContaining({ visibility: "private" }),
    );
    expect(out.announcements.join(" ")).toMatch(/privately about Jo/i);
    expect(out.announcements.join(" ")).toMatch(/won't see/i);
  });

  it("refuses the capture when the flag is off", async () => {
    const r = repo({ findPeople: vi.fn(async () => [joPerson]) });
    const out = await runCapture(
      batch("Jo has been stressed about work", { kind: "dm", userId: 1 }, [1]),
      deps({
        repo: r,
        extractor: extractorOf({
          people: [person("Jo")],
          memories: [memory("Jo", "has been stressed about work", 0.9)],
        }),
        participantUserIdFor: (id) => (id === 99 ? 2 : undefined),
        allowPrivateAboutParticipant: false,
      }),
    );

    expect(r.captureMemory).not.toHaveBeenCalled();
    expect(out.announcements.join(" ")).toMatch(/won't record/i);
  });

  it("says nothing extra for a private memory about a third party", async () => {
    // The announcement is about a participant, not about privacy in general.
    const out = await runCapture(
      batch("Sarah Chen is launching in August", { kind: "dm", userId: 1 }, [1]),
      deps({
        extractor: extractorOf({
          people: [person("Sarah Chen")],
          memories: [memory("Sarah Chen", "launching in August", 0.9)],
        }),
        participantUserIdFor: () => undefined,
      }),
    );
    expect(out.announcements).toEqual([]);
  });
});
```

Add to the `deps()` helper in that file:

```ts
    participantUserIdFor: () => undefined,
    allowPrivateAboutParticipant: true,
```

- [ ] **Step 2: Run and watch it fail**

Run: `pnpm vitest run tests/pipeline.test.ts`
Expected: FAIL — `announcements` is not on `CaptureOutcome`.

- [ ] **Step 3: Add the config flag**

`src/config.ts` schema, Config, and return:

```ts
  PRMM_ALLOW_PRIVATE_ABOUT_PARTICIPANT: z
    .enum(["true", "false"])
    .default("true"),
```

```ts
  /** When false, a DM refuses to store a memory about the other participant. */
  allowPrivateAboutParticipant: boolean;
```

```ts
    allowPrivateAboutParticipant:
      e.PRMM_ALLOW_PRIVATE_ABOUT_PARTICIPANT === "true",
```

`.env.example`:

```
# A DM can hold a private memory ABOUT the other participant. Allowed by
# default and always announced at capture. Set false to refuse instead.
PRMM_ALLOW_PRIVATE_ABOUT_PARTICIPANT=true
```

- [ ] **Step 4: Extend the pipeline**

In `src/pipeline.ts`, add to `CaptureDeps`:

```ts
  /** Maps a person id to the participant it represents, if any. */
  participantUserIdFor: (personId: number) => number | undefined;
  allowPrivateAboutParticipant: boolean;
```

Add to `CaptureOutcome`:

```ts
  /** Messages the bot must say out loud. Empty is the normal case. */
  announcements: string[];
```

Add `announcements: [] as string[]` to the `empty` literal so every early return carries it.

Declare `const announcements: string[] = [];` beside `questions`, include it in the final return, and guard the memory write:

```ts
    const aboutParticipant = deps.participantUserIdFor(personId);
    const aboutTheOther =
      isDm && aboutParticipant !== undefined && aboutParticipant !== userId;

    if (aboutTheOther && !deps.allowPrivateAboutParticipant) {
      // Refused by configuration. Say so — a silent drop is the failure this
      // whole section exists to prevent.
      announcements.push(
        `I won't record private notes about ${memory.about}. ` +
          `Say it in the group if you want it kept.`,
      );
      continue;
    }

    // ... existing captureMemory / recordInteraction calls ...

    if (aboutTheOther) {
      announcements.push(
        `Noted privately about ${memory.about}. ${memory.about} won't see this.`,
      );
    }
```

- [ ] **Step 5: Run the pipeline tests**

Run: `pnpm vitest run tests/pipeline.test.ts`
Expected: PASS — 3 new tests

- [ ] **Step 6: Speak the announcements**

In `src/index.ts`, build the participant map once at startup and speak whatever the capture returns:

```ts
  const participantRows = await inner.findParticipants();
  const participantUserId = new Map(
    participantRows.map((r) => [r.id, r.userId]),
  );
```

Add to `PgRepository`:

```ts
  /** Person rows that represent the two humans in the group. */
  async findParticipants(): Promise<{ id: number; userId: number }[]> {
    const rows = await this.sql<{ id: string; user_id: string }[]>`
      SELECT id::text, user_id::text FROM prmm.people WHERE is_participant
    `;
    return rows.map((r) => ({ id: toId(r.id), userId: toId(r.user_id) }));
  }
```

Pass into `runCapture`:

```ts
      participantUserIdFor: (id) => participantUserId.get(id),
      allowPrivateAboutParticipant: cfg.allowPrivateAboutParticipant,
```

and after the reaction, in the same `.then`:

```ts
      for (const line of out.announcements) {
        await session
          .sendText(batch.messages[0]?.chatJid ?? "", line)
          .catch((e: unknown) => console.error("announcement failed", e));
      }
```

- [ ] **Step 7: Add the cross-user visibility check**

Append to `tests/pg-integration.test.ts`:

```ts
  it("never returns the other user's private memories", async () => {
    // The private channel's entire premise. A regression here leaks personal
    // content between two people who trusted it.
    const [p] = await sql<{ id: string }[]>`
      INSERT INTO prmm.people (user_id, canonical_name, visibility)
      VALUES (1, 'Visibility Probe', 'shared') RETURNING id::text`;
    const personId = Number(p!.id);
    const [m] = await sql<{ id: string }[]>`
      INSERT INTO prmm.memories (content, user_id, visibility)
      VALUES ('user one private note', 1, 'private') RETURNING id::text`;
    await sql`INSERT INTO prmm.memory_people (memory_id, person_id)
              VALUES (${Number(m!.id)}, ${personId})`;

    expect(await repo.memoriesAbout(personId, 1)).toContain("user one private note");
    expect(await repo.memoriesAbout(personId, 2)).not.toContain("user one private note");

    await sql`DELETE FROM prmm.memories WHERE id = ${Number(m!.id)}`;
    await sql`DELETE FROM prmm.people WHERE id = ${personId}`;
  });
```

- [ ] **Step 8: Run everything**

Run: `pnpm test`, then `PRMM_DATABASE_URL=<voice url> pnpm vitest run tests/pg-integration.test.ts`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add src tests .env.example
git commit -m "feat: announce private memories about the other participant"
```

---

## Phase 1.5 exit criteria

- [ ] `pnpm test` green, nothing skipped
- [ ] `prmm` schema live in `voice`; `prmm-db` container removed
- [ ] `findPeople` returns >1,000 candidates from the contact book
- [ ] A capture of a known contact links `person_contact_id` instead of duplicating
- [ ] A message naming Jo produces a person row for Jo
- [ ] A bare unnamed number produces no person row (`pnpm eval` 6/6, 0 invented)
- [ ] A stored capture gets 📌; a degraded one gets ⚠️; a clarification gets ❓
- [ ] `@calvin where did I meet Jo?` answers and is never captured
- [ ] An unrecognised question names the four capabilities
- [ ] A question from user A never returns user B's private memories
- [ ] A DM memory about the other participant stores and announces who cannot see it
- [ ] With `PRMM_ALLOW_PRIVATE_ABOUT_PARTICIPANT=false` that capture is refused, out loud

## Deferred to Phase 2

Embeddings and semantic recall; the trigger scheduler and proactive nudges;
`triggers` and `clarifications` still have no consumer. Phase 3 adds the voice,
SMS, and app surfaces on top of `answerQuestion`, which is why it takes its
dependencies as an interface rather than reaching for the database directly.
