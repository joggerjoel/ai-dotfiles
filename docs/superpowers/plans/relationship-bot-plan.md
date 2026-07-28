# Relationship Bot — Phase 1 (Capture Path) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a WhatsApp bot that reads a two-person group, extracts people and facts from the conversation, resolves who those facts are about, and stores them in OpenBrain.

**Architecture:** A standalone Node/TypeScript service pairs to WhatsApp as a Baileys linked device. Inbound messages route by JID to one group and two DMs, buffer into debounced batches, pass a cheap relevance gate, then reach an Ollama-backed extractor that emits scored candidates. An identity resolver decides match/ask/create, and a repository writes through OpenBrain's FastAPI. A write-ahead queue on disk absorbs OpenBrain outages.

**Tech Stack:** Node 22, TypeScript (strict), pnpm, vitest, Baileys 7.0.0-rc13, zod, Ollama.

## Global Constraints

- **Reference implementation:** OpenClaw is an open-source personal-assistant gateway checked out at `~/Documents/Projects/openclaw`. Its production WhatsApp channel (`extensions/whatsapp/`, package `@openclaw/whatsapp`) runs Baileys as a linked device. Claims below citing "OpenClaw" are verifiable at `docs/channels/whatsapp.md` and `extensions/whatsapp/package.json` in that checkout.
- **Runtime: Node 22 LTS. Not Bun.** Baileys targets Node, and OpenClaw's `docs/channels/whatsapp.md` states its gateway requires Node because Bun lacks `node:sqlite`. This overrides the usual bun-first preference in `~/.claude/CLAUDE.md`.
- **Package manager: pnpm**, matching OpenClaw so borrowed code drops in cleanly.
- **TypeScript strict. No `any`, no `@ts-ignore`.**
- **Baileys pinned to `7.0.0-rc13`** — the exact version in OpenClaw's `extensions/whatsapp/package.json`.
- **Every outbound HTTP call carries a timeout.** A hung socket never rejects, so it never reaches a catch block and never queues. Use `AbortSignal.timeout(...)` on every `fetch`.
- **Confidence floor: 0.5.** Candidates below it are logged and discarded, never written. `llama3.1:8b` hallucinates; nothing low-confidence may reach durable storage.
- **No secrets in the repo.** All connection strings come from environment variables. `.env` is gitignored; `.env.example` holds placeholders only.
- **Credential directory is mode 700.** It holds a live WhatsApp session.
- **Repo root:** `~/Documents/Projects/prmm-bot`
- **All I/O is injected, never imported.** `transport/`, `extract/`, and `store/` each perform I/O (WhatsApp socket, Ollama HTTP, OpenBrain HTTP), but every one of them takes its `fetch`/socket as a constructor parameter, so tests substitute a fake. `capture/` and `resolve/` are genuinely pure. No module reaches the network through a module-level import.
- **No live WhatsApp in CI.** Transport tests drive a mock event emitter.

---

### Task 1: Project scaffold, config, and domain types

**Files:**

- Create: `package.json`, `tsconfig.json`, `vitest.config.ts`, `.gitignore`, `.env.example`
- Create: `src/types.ts`, `src/config.ts`
- Test: `tests/config.test.ts`

**Interfaces:**

- Consumes: nothing
- Produces: `InboundMessage`, `ChannelKind`, `UserBinding`, `Config`, `loadConfig(env: NodeJS.ProcessEnv): Config`

- [ ] **Step 1: Initialise the project**

```bash
mkdir -p ~/Documents/Projects/prmm-bot && cd ~/Documents/Projects/prmm-bot
git init
pnpm init
pnpm add baileys@7.0.0-rc13 zod
pnpm add -D typescript @types/node vitest tsx
```

- [ ] **Step 2: Write `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2023",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "dist",
    "rootDir": "."
  },
  "include": ["src", "tests"]
}
```

- [ ] **Step 3: Write `vitest.config.ts` and `.gitignore`**

`vitest.config.ts`:

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: { environment: "node", include: ["tests/**/*.test.ts"] },
});
```

`.gitignore`:

```
node_modules/
dist/
.env
auth/
queue/
```

- [ ] **Step 4: Write `.env.example`**

```
PRMM_GROUP_JID=000000000000000000@g.us
PRMM_USER_A_ID=1
PRMM_USER_A_E164=+15555550100
PRMM_USER_A_DM_JID=15555550100@s.whatsapp.net
PRMM_USER_B_ID=2
PRMM_USER_B_E164=+15555550101
PRMM_USER_B_DM_JID=15555550101@s.whatsapp.net
PRMM_OPENBRAIN_URL=http://localhost:3000
# Postgres DSN — migrations and manual psql verification only, never the bot's write path.
PRMM_OPENBRAIN_DSN=postgres://user@host:5432/openbrain
PRMM_OLLAMA_URL=http://localhost:11434
PRMM_OLLAMA_MODEL=llama3.1:8b
PRMM_AUTH_DIR=./auth
PRMM_QUEUE_DIR=./queue
PRMM_DEBOUNCE_MS=90000
# Leave unset only if OpenBrain is unreachable from outside the host.
PRMM_OPENBRAIN_TOKEN=
```

- [ ] **Step 5: Write `src/types.ts`**

```ts
export type ChannelKind = "group" | "dm";

export interface InboundMessage {
  id: string;
  chatJid: string;
  senderJid: string;
  /**
   * Null when the sender arrives as a privacy JID (`@lid`) that carries no
   * phone number. Callers must handle null loudly — never treat it as "unknown
   * sender, drop silently", which would make the bot go dark with no signal.
   */
  senderE164: string | null;
  text: string;
  timestamp: Date;
}

export interface UserBinding {
  userId: number;
  e164: string;
  dmJid: string;
}
```

- [ ] **Step 6: Write the failing test**

`tests/config.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";

const base = {
  PRMM_GROUP_JID: "123@g.us",
  PRMM_USER_A_ID: "1",
  PRMM_USER_A_E164: "+15555550100",
  PRMM_USER_A_DM_JID: "15555550100@s.whatsapp.net",
  PRMM_USER_B_ID: "2",
  PRMM_USER_B_E164: "+15555550101",
  PRMM_USER_B_DM_JID: "15555550101@s.whatsapp.net",
  PRMM_OPENBRAIN_URL: "http://localhost:3000",
  PRMM_OPENBRAIN_DSN: "postgres://voice@localhost:5432/openbrain",
  PRMM_OLLAMA_URL: "http://localhost:11434",
  PRMM_OLLAMA_MODEL: "llama3.1:8b",
  PRMM_AUTH_DIR: "./auth",
  PRMM_QUEUE_DIR: "./queue",
};

describe("loadConfig", () => {
  it("parses two user bindings", () => {
    const cfg = loadConfig(base);
    expect(cfg.groupJid).toBe("123@g.us");
    expect(cfg.users).toHaveLength(2);
    expect(cfg.users[0]?.userId).toBe(1);
    expect(cfg.users[1]?.dmJid).toBe("15555550101@s.whatsapp.net");
  });

  it("defaults the debounce window to 90 seconds", () => {
    expect(loadConfig(base).debounceMs).toBe(90_000);
  });

  it("throws when a required variable is missing", () => {
    const { PRMM_GROUP_JID: _omit, ...rest } = base;
    expect(() => loadConfig(rest)).toThrow(/PRMM_GROUP_JID/);
  });

  it("rejects a malformed numeric id rather than yielding NaN", () => {
    // NaN would flow silently into routing and into user_id on every write.
    expect(() => loadConfig({ ...base, PRMM_USER_A_ID: "abc" })).toThrow(
      /PRMM_USER_A_ID/,
    );
  });

  it("assigns a stable shared owner for group-discovered people", () => {
    // Must not depend on who happened to speak first in a batch.
    expect(loadConfig(base).sharedOwnerUserId).toBe(1);
  });
});
```

- [ ] **Step 7: Run the test and confirm it fails**

Run: `pnpm vitest run tests/config.test.ts`
Expected: FAIL — cannot find module `../src/config.js`

- [ ] **Step 8: Write `src/config.ts`**

```ts
import { z } from "zod";
import type { UserBinding } from "./types.js";

/**
 * Validated at load. A malformed numeric env var must fail here, not surface
 * later as `userId: NaN` flowing into routing and database writes.
 */
const EnvSchema = z.object({
  PRMM_GROUP_JID: z.string().min(1),
  PRMM_USER_A_ID: z.coerce.number().int().positive(),
  PRMM_USER_A_E164: z.string().regex(/^\+\d{6,}$/),
  PRMM_USER_A_DM_JID: z.string().min(1),
  PRMM_USER_B_ID: z.coerce.number().int().positive(),
  PRMM_USER_B_E164: z.string().regex(/^\+\d{6,}$/),
  PRMM_USER_B_DM_JID: z.string().min(1),
  PRMM_OPENBRAIN_URL: z.string().url(),
  PRMM_OPENBRAIN_DSN: z.string().min(1),
  PRMM_OPENBRAIN_TOKEN: z.string().optional(),
  PRMM_OLLAMA_URL: z.string().url(),
  PRMM_OLLAMA_MODEL: z.string().min(1),
  PRMM_AUTH_DIR: z.string().min(1),
  PRMM_QUEUE_DIR: z.string().min(1),
  PRMM_DEBOUNCE_MS: z.coerce.number().int().positive().default(90_000),
});

export interface Config {
  groupJid: string;
  users: UserBinding[];
  /**
   * Owner assigned to people discovered in the GROUP. Fixed rather than derived
   * from whoever spoke first, so the same third party always lands under one
   * owner regardless of message order.
   */
  sharedOwnerUserId: number;
  openbrainUrl: string;
  /** Postgres connection string — for migrations and manual verification only. */
  openbrainDsn: string;
  openbrainToken: string | null;
  ollamaUrl: string;
  ollamaModel: string;
  authDir: string;
  queueDir: string;
  debounceMs: number;
}

export function loadConfig(env: NodeJS.ProcessEnv): Config {
  const parsed = EnvSchema.safeParse(env);
  if (!parsed.success) {
    const detail = parsed.error.issues
      .map((issue) => `${issue.path.join(".")}: ${issue.message}`)
      .join("; ");
    throw new Error(`invalid configuration — ${detail}`);
  }
  const e = parsed.data;

  const users: UserBinding[] = [
    { userId: e.PRMM_USER_A_ID, e164: e.PRMM_USER_A_E164, dmJid: e.PRMM_USER_A_DM_JID },
    { userId: e.PRMM_USER_B_ID, e164: e.PRMM_USER_B_E164, dmJid: e.PRMM_USER_B_DM_JID },
  ];

  return {
    groupJid: e.PRMM_GROUP_JID,
    users,
    sharedOwnerUserId: Math.min(...users.map((u) => u.userId)),
    openbrainUrl: e.PRMM_OPENBRAIN_URL,
    openbrainDsn: e.PRMM_OPENBRAIN_DSN,
    openbrainToken: e.PRMM_OPENBRAIN_TOKEN ?? null,
    ollamaUrl: e.PRMM_OLLAMA_URL,
    ollamaModel: e.PRMM_OLLAMA_MODEL,
    authDir: e.PRMM_AUTH_DIR,
    queueDir: e.PRMM_QUEUE_DIR,
    debounceMs: e.PRMM_DEBOUNCE_MS,
  };
}
```

- [ ] **Step 9: Add the test script and run the suite**

Add to `package.json`:

```json
{
  "type": "module",
  "scripts": {
    "typecheck": "tsc --noEmit",
    "test": "pnpm typecheck && vitest run",
    "build": "tsc",
    "dev": "node --env-file=.env --import tsx src/index.ts"
  }
}
```

`"type": "module"` is required for the `.js`-suffixed ESM specifiers used
throughout. `typecheck` runs before vitest because vitest strips types without
checking them — without it "strict, no `any`" has no enforcement and violations
ship silently. `--env-file` is what actually loads `.env`; tsx does not.

Run: `pnpm test`
Expected: PASS — 5 tests

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: project scaffold, config loading, domain types"
```

---

### Task 2: Migration 009

**Files:**

- Create: `migrations/009_add_relationships.sql`
- Test: `tests/migration.test.ts`

**Interfaces:**

- Consumes: nothing
- Produces: tables `people`, `interactions`, `triggers`, `clarifications`, `thought_people`, `resolution_log`, `write_ops`; columns `thoughts.visibility` and `thoughts.confidence`; unique indexes `people_shared_name_uniq` and `people_private_name_uniq`

- [ ] **Step 1: Write the migration**

```sql
-- 009_add_relationships.sql — additive only

CREATE TABLE IF NOT EXISTS people (
  id                  BIGSERIAL PRIMARY KEY,
  user_id             BIGINT NOT NULL,
  canonical_name      TEXT NOT NULL,
  aliases             TEXT[] DEFAULT '{}',
  phone               TEXT,
  email               TEXT,
  company             TEXT,
  role                TEXT,
  relationship_type   TEXT,
  birthday            DATE,
  timezone            TEXT,
  comm_preference     TEXT,
  first_met_at        TIMESTAMPTZ,
  first_met_context   TEXT,
  last_interaction_at TIMESTAMPTZ,
  next_nudge_at       TIMESTAMPTZ,
  cadence_days        INTEGER,
  embedding           VECTOR(768),
  status              TEXT NOT NULL DEFAULT 'active',
  -- 'shared' people came from the group and belong to both users; 'private'
  -- people came from one user's DM. Owner id alone cannot express this — keying
  -- group people to a single user makes the OTHER user's DM captures miss them
  -- and duplicate every record.
  visibility          TEXT NOT NULL DEFAULT 'shared',
  metadata            JSONB NOT NULL DEFAULT '{}',
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Backstop against duplicate people from concurrent captures or queue replay.
-- Application-side resolution is best-effort; this is the guarantee.
CREATE UNIQUE INDEX IF NOT EXISTS people_shared_name_uniq
  ON people(lower(canonical_name))
  WHERE status = 'active' AND visibility = 'shared';

CREATE UNIQUE INDEX IF NOT EXISTS people_private_name_uniq
  ON people(user_id, lower(canonical_name))
  WHERE status = 'active' AND visibility = 'private';

CREATE INDEX IF NOT EXISTS people_user_idx     ON people(user_id);
CREATE INDEX IF NOT EXISTS people_nudge_idx    ON people(next_nudge_at) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS people_birthday_idx ON people(birthday) WHERE birthday IS NOT NULL;

CREATE TABLE IF NOT EXISTS interactions (
  id          BIGSERIAL PRIMARY KEY,
  person_id   BIGINT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  occurred_at TIMESTAMPTZ NOT NULL,
  channel     TEXT NOT NULL,
  summary     TEXT,
  raw_excerpt TEXT,
  captured_by BIGINT NOT NULL,
  participants BIGINT[] NOT NULL DEFAULT '{}',
  thought_id  BIGINT REFERENCES thoughts(id) ON DELETE SET NULL,
  status      TEXT NOT NULL DEFAULT 'extracted',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS interactions_person_idx ON interactions(person_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS interactions_status_idx ON interactions(status)
  WHERE status = 'unextracted';

CREATE TABLE IF NOT EXISTS triggers (
  id            BIGSERIAL PRIMARY KEY,
  person_id     BIGINT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  owner_user_id BIGINT NOT NULL,
  kind          TEXT NOT NULL,
  due_at        TIMESTAMPTZ NOT NULL,
  reason        TEXT,
  payload       JSONB NOT NULL DEFAULT '{}',
  status        TEXT NOT NULL DEFAULT 'pending',
  sent_at       TIMESTAMPTZ,
  resolved_at   TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS triggers_due_idx ON triggers(due_at) WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS clarifications (
  id            BIGSERIAL PRIMARY KEY,
  asked_user_id BIGINT NOT NULL,
  kind          TEXT NOT NULL,
  question      TEXT NOT NULL,
  context       JSONB NOT NULL DEFAULT '{}',
  status        TEXT NOT NULL DEFAULT 'pending',
  answer        TEXT,
  answered_at   TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS clarifications_pending_idx ON clarifications(asked_user_id)
  WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS thought_people (
  thought_id BIGINT NOT NULL REFERENCES thoughts(id) ON DELETE CASCADE,
  person_id  BIGINT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  role       TEXT NOT NULL DEFAULT 'subject',
  PRIMARY KEY (thought_id, person_id)
);

CREATE TABLE IF NOT EXISTS resolution_log (
  id                  BIGSERIAL PRIMARY KEY,
  candidate_name      TEXT NOT NULL,
  chosen_person_id    BIGINT REFERENCES people(id) ON DELETE SET NULL,
  score               NUMERIC(4,3),
  action              TEXT NOT NULL,
  confirmed_person_id BIGINT REFERENCES people(id) ON DELETE SET NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Idempotency ledger. A write that succeeded server-side but whose response was
-- lost gets replayed from the queue; without this that replay duplicates the row.
CREATE TABLE IF NOT EXISTS write_ops (
  op_id      TEXT PRIMARY KEY,
  kind       TEXT NOT NULL,
  result_id  BIGINT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE thoughts ADD COLUMN IF NOT EXISTS visibility TEXT NOT NULL DEFAULT 'shared';
-- Asserted rather than assumed: /capture is told to persist confidence, and a
-- missing column would drop the value in silence.
ALTER TABLE thoughts ADD COLUMN IF NOT EXISTS confidence NUMERIC(3,2);
CREATE INDEX IF NOT EXISTS thoughts_visibility_idx ON thoughts(visibility, user_id);
```

- [ ] **Step 2: Write the guard test**

The migration is data, not behaviour, so this test pins its invariants rather
than driving its design — it passes immediately and stays as a regression guard.

`tests/migration.test.ts`:

```ts
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const sql = readFileSync("migrations/009_add_relationships.sql", "utf8");

describe("migration 009", () => {
  it("is additive — creates no destructive statements", () => {
    expect(sql).not.toMatch(/DROP\s+(TABLE|COLUMN)/i);
    expect(sql).not.toMatch(/ALTER\s+TABLE\s+\w+\s+DROP/i);
  });

  it("adds visibility with a safe default for existing rows", () => {
    expect(sql).toMatch(
      /ADD COLUMN IF NOT EXISTS visibility TEXT NOT NULL DEFAULT 'shared'/,
    );
  });

  it("creates every table the plan depends on", () => {
    for (const table of [
      "people",
      "interactions",
      "triggers",
      "clarifications",
      "thought_people",
      "resolution_log",
      "write_ops",
    ]) {
      expect(sql).toMatch(new RegExp(`CREATE TABLE IF NOT EXISTS ${table}\\b`));
    }
  });

  it("is re-runnable", () => {
    const creates = sql.match(/CREATE TABLE(?! IF NOT EXISTS)/g);
    expect(creates).toBeNull();
  });
});
```

- [ ] **Step 3: Run the test**

Run: `pnpm vitest run tests/migration.test.ts`
Expected: PASS — 4 tests

- [ ] **Step 4: Apply against a scratch database**

No prerequisite needed — this is a throwaway database, and running it here is what makes Step 5 safe. Never point this at the live instance:

```bash
# Structure only, no rows, so the scratch copy matches the real schema.
pg_dump --schema-only --no-owner "$PRMM_OPENBRAIN_DSN" > /tmp/openbrain-base-schema.sql

createdb prmm_scratch
psql -d prmm_scratch -c "CREATE EXTENSION IF NOT EXISTS vector;"
psql -d prmm_scratch -f /tmp/openbrain-base-schema.sql
psql -d prmm_scratch -f migrations/009_add_relationships.sql
psql -d prmm_scratch -c "\d people"
```

Expected: the table prints with 23 columns. Re-run the migration; expect no errors.

- [ ] **Step 5: Apply to the real OpenBrain database**

Gated on Prerequisite 2 (which Postgres instance). Task 11's smoke test queries
these tables on the live database, so verifying only against the scratch copy
leaves them missing where it counts.

```bash
psql "$PRMM_OPENBRAIN_DSN" -c "\\d thoughts" | head -5   # confirm the right instance
psql "$PRMM_OPENBRAIN_DSN" -f migrations/009_add_relationships.sql
psql "$PRMM_OPENBRAIN_DSN" -c "SELECT COUNT(*) FROM people;"
psql "$PRMM_OPENBRAIN_DSN" -c "SELECT visibility FROM thoughts LIMIT 1;"
```

Expected: `0` people, and existing thoughts reporting `shared`. If pre-existing
rows come back NULL, the column default did not apply — stop and fix before
continuing, because every visibility check downstream depends on it.

- [ ] **Step 6: Commit**

```bash
git add migrations tests/migration.test.ts
git commit -m "feat: add migration 009 for relationship tables"
```

---

### Task 3: Message normalisation and channel routing

**Files:**

- Create: `src/transport/normalize.ts`, `src/transport/router.ts`
- Test: `tests/router.test.ts`

**Interfaces:**

- Consumes: `InboundMessage`, `Config` (Task 1)
- Produces: `normalizeMessage(raw: WAMessageLike): InboundMessage | null`, `Route`, `routeMessage(msg: InboundMessage, cfg: Config): Route`

- [ ] **Step 1: Write the failing test**

`tests/router.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";
import { routeMessage } from "../src/transport/router.js";
import type { InboundMessage } from "../src/types.js";

const cfg = loadConfig({
  PRMM_GROUP_JID: "123@g.us",
  PRMM_USER_A_ID: "1",
  PRMM_USER_A_E164: "+15555550100",
  PRMM_USER_A_DM_JID: "15555550100@s.whatsapp.net",
  PRMM_USER_B_ID: "2",
  PRMM_USER_B_E164: "+15555550101",
  PRMM_USER_B_DM_JID: "15555550101@s.whatsapp.net",
  PRMM_OPENBRAIN_URL: "http://x",
  PRMM_OPENBRAIN_DSN: "postgres://u@h:5432/d",
  PRMM_OLLAMA_URL: "http://y",
  PRMM_OLLAMA_MODEL: "m",
  PRMM_AUTH_DIR: "./auth",
  PRMM_QUEUE_DIR: "./queue",
});

function msg(chatJid: string, senderE164: string | null): InboundMessage {
  return {
    id: "m1",
    chatJid,
    senderJid: senderE164 ? `${senderE164.slice(1)}@s.whatsapp.net` : "99@lid",
    senderE164,
    text: "hello",
    timestamp: new Date("2026-07-26T12:00:00Z"),
  };
}

describe("routeMessage", () => {
  it("routes the allowlisted group and carries the sender's userId", () => {
    expect(routeMessage(msg("123@g.us", "+15555550100"), cfg)).toEqual({
      kind: "group",
      userId: 1,
    });
  });

  it("attributes each group message to its own sender", () => {
    expect(routeMessage(msg("123@g.us", "+15555550101"), cfg)).toEqual({
      kind: "group",
      userId: 2,
    });
  });

  it("routes a known user's DM to that user", () => {
    expect(
      routeMessage(msg("15555550101@s.whatsapp.net", "+15555550101"), cfg),
    ).toEqual({ kind: "dm", userId: 2 });
  });

  it("ignores an unknown group", () => {
    const route = routeMessage(msg("999@g.us", "+15555550100"), cfg);
    expect(route).toEqual({ kind: "ignore", reason: "chat-not-allowlisted" });
  });

  it("ignores an unknown sender inside the allowlisted group", () => {
    const route = routeMessage(msg("123@g.us", "+15555559999"), cfg);
    expect(route).toEqual({ kind: "ignore", reason: "unknown-sender" });
  });

  it("ignores a DM from a stranger", () => {
    const route = routeMessage(
      msg("15555559999@s.whatsapp.net", "+15555559999"),
      cfg,
    );
    expect(route).toEqual({ kind: "ignore", reason: "chat-not-allowlisted" });
  });

  it("distinguishes an unmappable @lid sender from a stranger", () => {
    // Must NOT look like an outsider: this is our group, and going quiet here
    // would mean the bot silently stops working with no signal.
    const route = routeMessage(msg("123@g.us", null), cfg);
    expect(route).toEqual({ kind: "ignore", reason: "unresolved-sender" });
  });
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `pnpm vitest run tests/router.test.ts`
Expected: FAIL — cannot find module `../src/transport/router.js`

- [ ] **Step 3: Write `src/transport/router.ts`**

```ts
import type { Config } from "../config.js";
import type { InboundMessage } from "../types.js";

export type Route =
  // userId is the sender of THIS message, carried so attribution never has to
  // be re-derived downstream from an arbitrary message in the batch.
  | { kind: "group"; userId: number }
  | { kind: "dm"; userId: number }
  | { kind: "ignore"; reason: IgnoreReason };

export type IgnoreReason =
  "unresolved-sender" | "unknown-sender" | "chat-not-allowlisted";

export function routeMessage(msg: InboundMessage, cfg: Config): Route {
  const onAllowlistedChat =
    msg.chatJid === cfg.groupJid ||
    cfg.users.some((u) => u.dmJid === msg.chatJid);

  // A null E164 means a privacy JID we could not map. On a chat we care about
  // this is an operational fault, not a stranger — it must be distinguishable
  // from a genuine outsider so the caller can alarm rather than shrug.
  if (msg.senderE164 === null) {
    return {
      kind: "ignore",
      reason: onAllowlistedChat ? "unresolved-sender" : "chat-not-allowlisted",
    };
  }

  const sender = cfg.users.find((u) => u.e164 === msg.senderE164);

  if (msg.chatJid === cfg.groupJid) {
    return sender
      ? { kind: "group", userId: sender.userId }
      : { kind: "ignore", reason: "unknown-sender" };
  }

  const dmOwner = cfg.users.find((u) => u.dmJid === msg.chatJid);
  if (dmOwner && sender?.userId === dmOwner.userId) {
    return { kind: "dm", userId: dmOwner.userId };
  }

  return { kind: "ignore", reason: "chat-not-allowlisted" };
}
```

- [ ] **Step 4: Write `src/transport/normalize.ts`**

```ts
import type { InboundMessage } from "../types.js";

export interface WAContent {
  conversation?: string | null;
  extendedTextMessage?: { text?: string | null } | null;
  // WhatsApp wraps the real payload when disappearing / view-once is enabled.
  ephemeralMessage?: { message?: WAContent | null } | null;
  viewOnceMessage?: { message?: WAContent | null } | null;
  viewOnceMessageV2?: { message?: WAContent | null } | null;
  documentWithCaptionMessage?: { message?: WAContent | null } | null;
}

export interface WAMessageLike {
  key: {
    id?: string | null;
    remoteJid?: string | null;
    participant?: string | null;
    /** Baileys populates this with the phone JID when `participant` is a `@lid`. */
    participantAlt?: string | null;
    fromMe?: boolean | null;
  };
  message?: WAContent | null;
  messageTimestamp?: number | Long | null;
}

interface Long {
  toNumber(): number;
}

function toEpochSeconds(value: number | Long | null | undefined): number {
  if (typeof value === "number") return value;
  if (value && typeof value.toNumber === "function") return value.toNumber();
  return 0;
}

/** Returns null for `@lid` and any other JID carrying no phone number. */
function jidToE164(jid: string): string | null {
  if (!jid.endsWith("@s.whatsapp.net") && !jid.endsWith("@c.us")) return null;
  const digits = jid.split("@")[0]?.split(":")[0] ?? "";
  return /^\d{6,}$/.test(digits) ? `+${digits}` : null;
}

/**
 * Peel wrapper envelopes until the text payload is reachable. A group with
 * disappearing messages enabled delivers everything inside `ephemeralMessage`;
 * without this the entire capture path goes dark with no error.
 */
function unwrap(
  content: WAContent | null | undefined,
  depth = 0,
): WAContent | null {
  if (!content || depth > 4) return content ?? null;
  const inner =
    content.ephemeralMessage?.message ??
    content.viewOnceMessage?.message ??
    content.viewOnceMessageV2?.message ??
    content.documentWithCaptionMessage?.message;
  return inner ? unwrap(inner, depth + 1) : content;
}

export function normalizeMessage(raw: WAMessageLike): InboundMessage | null {
  if (raw.key.fromMe) return null;

  const chatJid = raw.key.remoteJid;
  const id = raw.key.id;
  if (!chatJid || !id) return null;
  if (chatJid === "status@broadcast" || chatJid.endsWith("@broadcast"))
    return null;

  const content = unwrap(raw.message);
  const text =
    content?.conversation ?? content?.extendedTextMessage?.text ?? "";
  if (!text.trim()) return null;

  // participantAlt carries the phone JID when participant is a privacy `@lid`.
  const senderJid = raw.key.participant ?? chatJid;
  const phoneJid = raw.key.participantAlt ?? senderJid;

  return {
    id,
    chatJid,
    senderJid,
    senderE164: jidToE164(phoneJid),
    text,
    timestamp: new Date(toEpochSeconds(raw.messageTimestamp) * 1000),
  };
}
```

- [ ] **Step 5: Add normalisation tests**

Append to `tests/router.test.ts`:

```ts
import { normalizeMessage } from "../src/transport/normalize.js";

describe("normalizeMessage", () => {
  it("extracts text and sender from a group message", () => {
    const out = normalizeMessage({
      key: {
        id: "A1",
        remoteJid: "123@g.us",
        participant: "15555550100@s.whatsapp.net",
      },
      message: { conversation: "met Sarah today" },
      messageTimestamp: 1785000000,
    });
    expect(out?.text).toBe("met Sarah today");
    expect(out?.senderE164).toBe("+15555550100");
  });

  it("drops our own messages", () => {
    expect(
      normalizeMessage({
        key: { id: "A2", remoteJid: "123@g.us", fromMe: true },
        message: { conversation: "hi" },
      }),
    ).toBeNull();
  });

  it("drops status broadcasts and empty bodies", () => {
    expect(
      normalizeMessage({
        key: { id: "A3", remoteJid: "status@broadcast" },
        message: { conversation: "x" },
      }),
    ).toBeNull();
    expect(
      normalizeMessage({
        key: { id: "A4", remoteJid: "123@g.us" },
        message: { conversation: "   " },
      }),
    ).toBeNull();
  });

  it("unwraps disappearing messages", () => {
    // If the group has disappearing messages on, EVERY message arrives wrapped.
    // Failing to unwrap takes the whole capture path dark with no error.
    const out = normalizeMessage({
      key: {
        id: "A5",
        remoteJid: "123@g.us",
        participant: "15555550100@s.whatsapp.net",
      },
      message: { ephemeralMessage: { message: { conversation: "met Sarah" } } },
      messageTimestamp: 1785000000,
    });
    expect(out?.text).toBe("met Sarah");
  });

  it("unwraps nested view-once inside ephemeral", () => {
    const out = normalizeMessage({
      key: {
        id: "A6",
        remoteJid: "123@g.us",
        participant: "15555550100@s.whatsapp.net",
      },
      message: {
        ephemeralMessage: {
          message: {
            viewOnceMessageV2: { message: { conversation: "secret" } },
          },
        },
      },
      messageTimestamp: 1785000000,
    });
    expect(out?.text).toBe("secret");
  });

  it("maps a @lid sender through participantAlt when available", () => {
    const out = normalizeMessage({
      key: {
        id: "A7",
        remoteJid: "123@g.us",
        participant: "8873847384@lid",
        participantAlt: "15555550100@s.whatsapp.net",
      },
      message: { conversation: "hi" },
      messageTimestamp: 1785000000,
    });
    expect(out?.senderE164).toBe("+15555550100");
  });

  it("yields a null E164 for an unmappable @lid rather than a bogus number", () => {
    const out = normalizeMessage({
      key: { id: "A8", remoteJid: "123@g.us", participant: "8873847384@lid" },
      message: { conversation: "hi" },
      messageTimestamp: 1785000000,
    });
    expect(out?.senderE164).toBeNull();
  });
});
```

- [ ] **Step 6: Run the tests**

Run: `pnpm vitest run tests/router.test.ts`
Expected: PASS — 14 tests

- [ ] **Step 7: Commit**

```bash
git add src/transport tests/router.test.ts
git commit -m "feat: normalise inbound messages and route by JID allowlist"
```

---

### Task 4: Capture buffer

**Files:**

- Create: `src/capture/buffer.ts`
- Test: `tests/buffer.test.ts`

**Interfaces:**

- Consumes: `InboundMessage` (Task 1), `Route` (Task 3)
- Produces: `CaptureBatch`, `CaptureBuffer` with `add(msg, route)`, `flushAll()`, `dispose()`

- [ ] **Step 1: Write the failing test**

`tests/buffer.test.ts`:

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CaptureBuffer, type CaptureBatch } from "../src/capture/buffer.js";
import type { InboundMessage } from "../src/types.js";

function msg(id: string, text: string, e164 = "+15555550100"): InboundMessage {
  return {
    id,
    chatJid: "123@g.us",
    senderJid: `${e164.slice(1)}@s.whatsapp.net`,
    senderE164: e164,
    text,
    timestamp: new Date(),
  };
}

describe("CaptureBuffer", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("flushes after the debounce window elapses", () => {
    const batches: CaptureBatch[] = [];
    const buf = new CaptureBuffer(1000, (b) => batches.push(b));
    buf.add(msg("1", "met Sarah"), { kind: "group", userId: 1 });
    expect(batches).toHaveLength(0);
    vi.advanceTimersByTime(1000);
    expect(batches).toHaveLength(1);
    expect(batches[0]?.messages).toHaveLength(1);
  });

  it("extends the window when another message arrives", () => {
    const batches: CaptureBatch[] = [];
    const buf = new CaptureBuffer(1000, (b) => batches.push(b));
    buf.add(msg("1", "a"), { kind: "group", userId: 1 });
    vi.advanceTimersByTime(600);
    buf.add(msg("2", "b"), { kind: "group", userId: 1 });
    vi.advanceTimersByTime(600);
    expect(batches).toHaveLength(0);
    vi.advanceTimersByTime(400);
    expect(batches[0]?.messages).toHaveLength(2);
  });

  it("keeps group and DM traffic in separate batches", () => {
    const batches: CaptureBatch[] = [];
    const buf = new CaptureBuffer(1000, (b) => batches.push(b));
    buf.add(msg("1", "group msg"), { kind: "group", userId: 1 });
    buf.add(msg("2", "dm msg"), { kind: "dm", userId: 1 });
    vi.advanceTimersByTime(1000);
    expect(batches).toHaveLength(2);
    expect(batches.map((b) => b.route.kind).sort()).toEqual(["dm", "group"]);
  });

  it("records every participant when both users speak in one batch", () => {
    // The normal case in a two-person group. Attributing the whole batch to
    // whoever spoke first would misattribute the other user's content.
    const batches: CaptureBatch[] = [];
    const buf = new CaptureBuffer(1000, (b) => batches.push(b));
    buf.add(msg("1", "met Sarah", "+15555550100"), {
      kind: "group",
      userId: 1,
    });
    buf.add(msg("2", "which Sarah?", "+15555550101"), {
      kind: "group",
      userId: 2,
    });
    buf.add(msg("3", "Chen", "+15555550100"), { kind: "group", userId: 1 });
    vi.advanceTimersByTime(1000);
    expect(batches[0]?.participants).toEqual([1, 2]);
  });

  it("flushes on the hard cap even while messages keep arriving", () => {
    // Without an absolute cap, a steady conversation never reaches the debounce
    // window and the batch grows until it blows the model's context.
    const batches: CaptureBatch[] = [];
    const buf = new CaptureBuffer(60_000, (b) => batches.push(b));
    for (let i = 0; i < 70; i += 1) {
      buf.add(msg(String(i), `message ${i}`), { kind: "group", userId: 1 });
    }
    expect(batches).toHaveLength(1);
    expect(batches[0]?.messages.length).toBeLessThanOrEqual(60);
  });

  it("flushAll drains immediately without waiting", () => {
    const batches: CaptureBatch[] = [];
    const buf = new CaptureBuffer(10_000, (b) => batches.push(b));
    buf.add(msg("1", "a"), { kind: "group", userId: 1 });
    buf.flushAll();
    expect(batches).toHaveLength(1);
  });

  it("dispose cancels pending timers without flushing", () => {
    const batches: CaptureBatch[] = [];
    const buf = new CaptureBuffer(1000, (b) => batches.push(b));
    buf.add(msg("1", "a"), { kind: "group", userId: 1 });
    buf.dispose();
    vi.advanceTimersByTime(5000);
    expect(batches).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `pnpm vitest run tests/buffer.test.ts`
Expected: FAIL — cannot find module `../src/capture/buffer.js`

- [ ] **Step 3: Write `src/capture/buffer.ts`**

```ts
import type { Route } from "../transport/router.js";
import type { InboundMessage } from "../types.js";

export interface CaptureBatch {
  route: Route;
  messages: InboundMessage[];
  /**
   * Every user who spoke in this batch, in order of first appearance. A group
   * batch normally spans BOTH users, so attributing it to whoever happened to
   * speak first would misattribute the rest. Group content is `shared`, so this
   * records provenance rather than gating access.
   */
  participants: number[];
  closedAt: Date;
}

type Pending = {
  route: Route;
  messages: InboundMessage[];
  participants: number[];
  openedAt: number;
  timer: NodeJS.Timeout;
  /** Absolute cap, never extended — the debounce timer alone can starve. */
  hardTimer: NodeJS.Timeout;
};

function keyFor(route: Route): string {
  return route.kind === "dm" ? `dm:${route.userId}` : route.kind;
}

/** A steady conversation must still flush; debounce alone can defer forever. */
const MAX_BATCH_AGE_MS = 15 * 60_000;
const MAX_BATCH_MESSAGES = 60;

export class CaptureBuffer {
  private readonly pending = new Map<string, Pending>();

  constructor(
    private readonly debounceMs: number,
    private readonly onFlush: (batch: CaptureBatch) => void,
  ) {}

  add(message: InboundMessage, route: Route): void {
    if (route.kind === "ignore") return;

    const key = keyFor(route);
    const existing = this.pending.get(key);

    if (existing) {
      clearTimeout(existing.timer);
      existing.messages.push(message);
      if (!existing.participants.includes(route.userId)) {
        existing.participants.push(route.userId);
      }
      // A conversation with gaps under the debounce window would otherwise never
      // flush: the batch grows unbounded and eventually blows the model context.
      if (existing.messages.length >= MAX_BATCH_MESSAGES) {
        this.flush(key);
        return;
      }
      existing.timer = setTimeout(() => this.flush(key), this.debounceMs);
      return;
    }

    const openedAt = Date.now();
    this.pending.set(key, {
      route,
      messages: [message],
      participants: [route.userId],
      openedAt,
      timer: setTimeout(() => this.flush(key), this.debounceMs),
      hardTimer: setTimeout(() => this.flush(key), MAX_BATCH_AGE_MS),
    });
  }

  private flush(key: string): void {
    const entry = this.pending.get(key);
    if (!entry) return;
    clearTimeout(entry.timer);
    clearTimeout(entry.hardTimer);
    this.pending.delete(key);
    this.onFlush({
      route: entry.route,
      messages: entry.messages,
      participants: entry.participants,
      closedAt: new Date(),
    });
  }

  flushAll(): void {
    for (const key of [...this.pending.keys()]) this.flush(key);
  }

  dispose(): void {
    for (const entry of this.pending.values()) {
      clearTimeout(entry.timer);
      clearTimeout(entry.hardTimer);
    }
    this.pending.clear();
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `pnpm vitest run tests/buffer.test.ts`
Expected: PASS — 7 tests

- [ ] **Step 5: Commit**

```bash
git add src/capture tests/buffer.test.ts
git commit -m "feat: debounced capture buffer with per-channel batching"
```

---

### Task 5: Extraction schemas and the relevance gate

**Files:**

- Create: `src/extract/schema.ts`, `src/extract/gate.ts`
- Test: `tests/gate.test.ts`

**Interfaces:**

- Consumes: `CaptureBatch` (Task 4)
- Produces: `ExtractionResult`, `ExtractionResultSchema`, `PersonCandidate`, `MemoryCandidate`, `CommitmentCandidate`, `DateCandidate`, `looksRelevant(text: string): boolean`

- [ ] **Step 1: Write `src/extract/schema.ts`**

```ts
import { z } from "zod";

const confidence = z.number().min(0).max(1);

export const PersonCandidateSchema = z.object({
  name: z.string().min(1),
  aliases: z.array(z.string()).default([]),
  company: z.string().nullable().default(null),
  context: z.string().default(""),
  confidence,
});

export const MemoryCandidateSchema = z.object({
  about: z.string().min(1),
  content: z.string().min(1),
  category: z
    .enum(["relationship", "project", "temporal", "decision"])
    .default("relationship"),
  confidence,
});

export const CommitmentCandidateSchema = z.object({
  owner: z.string().min(1),
  what: z.string().min(1),
  due: z.string().nullable().default(null),
  confidence,
});

export const DateCandidateSchema = z.object({
  person: z.string().min(1),
  kind: z.enum(["birthday", "launch", "meeting", "other"]).default("other"),
  date: z.string(),
  confidence,
});

export const ExtractionResultSchema = z.object({
  people: z.array(PersonCandidateSchema).default([]),
  memories: z.array(MemoryCandidateSchema).default([]),
  commitments: z.array(CommitmentCandidateSchema).default([]),
  dates: z.array(DateCandidateSchema).default([]),
});

export type PersonCandidate = z.infer<typeof PersonCandidateSchema>;
export type MemoryCandidate = z.infer<typeof MemoryCandidateSchema>;
export type CommitmentCandidate = z.infer<typeof CommitmentCandidateSchema>;
export type DateCandidate = z.infer<typeof DateCandidateSchema>;
export type ExtractionResult = z.infer<typeof ExtractionResultSchema>;
```

- [ ] **Step 2: Write the failing test**

`tests/gate.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { looksRelevant } from "../src/extract/gate.js";
import { ExtractionResultSchema } from "../src/extract/schema.js";

describe("looksRelevant", () => {
  it("passes text naming a person", () => {
    expect(looksRelevant("had coffee with Sarah Chen today")).toBe(true);
  });

  it("passes text containing a commitment verb", () => {
    expect(looksRelevant("i promised to send him the deck")).toBe(true);
  });

  it("passes text containing a date", () => {
    expect(looksRelevant("the launch is in August")).toBe(true);
  });

  it("rejects small talk", () => {
    expect(looksRelevant("lol yeah")).toBe(false);
    expect(looksRelevant("ok")).toBe(false);
    expect(looksRelevant("haha same here")).toBe(false);
  });

  it("rejects a sentence-initial capital alone", () => {
    expect(looksRelevant("Sounds good to me")).toBe(false);
  });
});

describe("ExtractionResultSchema", () => {
  it("fills defaults for omitted arrays", () => {
    expect(ExtractionResultSchema.parse({})).toEqual({
      people: [],
      memories: [],
      commitments: [],
      dates: [],
    });
  });

  it("rejects confidence outside 0..1", () => {
    expect(() =>
      ExtractionResultSchema.parse({
        people: [{ name: "Sarah", confidence: 1.5 }],
      }),
    ).toThrow();
  });
});
```

- [ ] **Step 3: Run the test and confirm it fails**

Run: `pnpm vitest run tests/gate.test.ts`
Expected: FAIL — cannot find module `../src/extract/gate.js`

- [ ] **Step 4: Write `src/extract/gate.ts`**

```ts
const COMMITMENT_VERBS =
  /\b(promis\w*|introduc\w*|send|share|follow up|connect|refer|owe|remind)\b/i;

const DATE_HINTS =
  /\b(january|february|march|april|may|june|july|august|september|october|november|december|monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|next week|next month|birthday|\d{1,2}\/\d{1,2}|\d{4}-\d{2}-\d{2})\b/i;

const STOPWORDS = new Set([
  "I",
  "I'm",
  "Ok",
  "Okay",
  "Yeah",
  "Yes",
  "No",
  "Lol",
  "Haha",
  "Sounds",
  "Thanks",
  "Nice",
  "Cool",
  "Sure",
  "Great",
  "Good",
  "Hey",
  "Hi",
]);

/** Cheap pre-filter: does this text plausibly carry a person, commitment, or date? */
export function looksRelevant(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.length < 8) return false;
  if (COMMITMENT_VERBS.test(trimmed) || DATE_HINTS.test(trimmed)) return true;

  // A capitalised token that is not the first word and not a stopword reads as a name.
  const tokens = trimmed.split(/\s+/);
  return tokens
    .slice(1)
    .some((token) => /^[A-Z][a-z]{2,}$/.test(token) && !STOPWORDS.has(token));
}
```

- [ ] **Step 5: Run the tests**

Run: `pnpm vitest run tests/gate.test.ts`
Expected: PASS — 7 tests

- [ ] **Step 6: Commit**

```bash
git add src/extract tests/gate.test.ts
git commit -m "feat: extraction schemas and heuristic relevance gate"
```

---

### Task 6: Ollama-backed extractor

**Files:**

- Create: `src/extract/extractor.ts`
- Test: `tests/extractor.test.ts`

**Interfaces:**

- Consumes: `ExtractionResultSchema` (Task 5), `CaptureBatch` (Task 4)
- Produces: `Extractor` interface, `OllamaExtractor` with `extract(batch: CaptureBatch): Promise<ExtractionResult>`, `buildPrompt(batch): string`

- [ ] **Step 1: Write the failing test**

`tests/extractor.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import { OllamaExtractor } from "../src/extract/extractor.js";
import type { CaptureBatch } from "../src/capture/buffer.js";

function batch(...texts: string[]): CaptureBatch {
  return {
    route: { kind: "group", userId: 1 },
    participants: [1],
    closedAt: new Date("2026-07-26T12:00:00Z"),
    messages: texts.map((text, i) => ({
      id: `m${i}`,
      chatJid: "123@g.us",
      senderJid: "s@s.whatsapp.net",
      senderE164: "+15555550100",
      text,
      timestamp: new Date("2026-07-26T12:00:00Z"),
    })),
  };
}

function fakeFetch(payload: unknown) {
  return vi.fn(
    async () =>
      new Response(
        JSON.stringify({ message: { content: JSON.stringify(payload) } }),
        { status: 200 },
      ),
  );
}

describe("OllamaExtractor", () => {
  it("parses a well-formed response", async () => {
    const fetchImpl = fakeFetch({
      people: [
        {
          name: "Sarah Chen",
          company: "Acme",
          context: "robotics conf",
          confidence: 0.9,
        },
      ],
      memories: [],
      commitments: [],
      dates: [],
    });
    const ex = new OllamaExtractor(
      "http://ollama",
      "m",
      fetchImpl as unknown as typeof fetch,
    );
    const out = await ex.extract(
      batch("met Sarah Chen at the robotics conference"),
    );
    expect(out.people[0]?.name).toBe("Sarah Chen");
    expect(out.memories).toEqual([]);
  });

  it("retries once when the model returns malformed JSON", async () => {
    const bad = new Response(
      JSON.stringify({ message: { content: "not json" } }),
      { status: 200 },
    );
    const good = new Response(
      JSON.stringify({
        message: {
          content: JSON.stringify({
            people: [],
            memories: [],
            commitments: [],
            dates: [],
          }),
        },
      }),
      { status: 200 },
    );
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(bad)
      .mockResolvedValueOnce(good);

    const ex = new OllamaExtractor(
      "http://ollama",
      "m",
      fetchImpl as unknown as typeof fetch,
    );
    await expect(ex.extract(batch("hello there Sarah"))).resolves.toEqual({
      people: [],
      memories: [],
      commitments: [],
      dates: [],
    });
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("throws after a second malformed response so the caller can park the batch", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response(
          JSON.stringify({ message: { content: "still not json" } }),
          { status: 200 },
        ),
    );
    const ex = new OllamaExtractor(
      "http://ollama",
      "m",
      fetchImpl as unknown as typeof fetch,
    );
    await expect(ex.extract(batch("hello there Sarah"))).rejects.toThrow(
      /extraction failed/i,
    );
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("includes sender and text in the prompt", async () => {
    const fetchImpl = fakeFetch({
      people: [],
      memories: [],
      commitments: [],
      dates: [],
    });
    const ex = new OllamaExtractor(
      "http://ollama",
      "m",
      fetchImpl as unknown as typeof fetch,
    );
    await ex.extract(batch("met Sarah Chen"));
    const body = JSON.parse(String(fetchImpl.mock.calls[0]?.[1]?.body));
    expect(body.messages[1].content).toContain("met Sarah Chen");
    expect(body.format).toBe("json");
  });
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `pnpm vitest run tests/extractor.test.ts`
Expected: FAIL — cannot find module `../src/extract/extractor.js`

- [ ] **Step 3: Write `src/extract/extractor.ts`**

```ts
import type { CaptureBatch } from "../capture/buffer.js";
import { ExtractionResultSchema, type ExtractionResult } from "./schema.js";

export interface Extractor {
  extract(batch: CaptureBatch): Promise<ExtractionResult>;
}

/** Local 8B inference on a batch is slow but bounded; beyond this it is stuck. */
const EXTRACTION_TIMEOUT_MS = 120_000;

const SYSTEM_PROMPT = `You extract relationship facts from chat transcripts.
Return ONLY JSON matching this shape:
{"people":[{"name":"","aliases":[],"company":null,"context":"","confidence":0.0}],
 "memories":[{"about":"","content":"","category":"relationship","confidence":0.0}],
 "commitments":[{"owner":"","what":"","due":null,"confidence":0.0}],
 "dates":[{"person":"","kind":"other","date":"","confidence":0.0}]}
Rules:
- The transcript is labelled with participants' phone numbers. Record only people
  discussed BY name; never turn a participant's phone number into a person.
- confidence is 0.0-1.0. Use below 0.5 when you are guessing.
- Omit anything you did not read in the transcript. Never invent a detail.
- Use empty arrays when nothing applies.`;

export function buildPrompt(batch: CaptureBatch): string {
  const lines = batch.messages
    .map((m) => `${m.senderE164}: ${m.text}`)
    .join("\n");
  return `Transcript (${batch.closedAt.toISOString()}):\n${lines}`;
}

export class OllamaExtractor implements Extractor {
  constructor(
    private readonly baseUrl: string,
    private readonly model: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  private async call(prompt: string): Promise<unknown> {
    const res = await this.fetchImpl(`${this.baseUrl}/api/chat`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      // Without this a hung Ollama never rejects, so the batch never reaches
      // the catch block and never gets parked — it just vanishes.
      signal: AbortSignal.timeout(EXTRACTION_TIMEOUT_MS),
      body: JSON.stringify({
        model: this.model,
        stream: false,
        format: "json",
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: prompt },
        ],
      }),
    });

    if (!res.ok) throw new Error(`ollama responded ${res.status}`);
    const body = (await res.json()) as { message?: { content?: string } };
    return JSON.parse(body.message?.content ?? "");
  }

  async extract(batch: CaptureBatch): Promise<ExtractionResult> {
    const prompt = buildPrompt(batch);

    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        return ExtractionResultSchema.parse(await this.call(prompt));
      } catch (error) {
        if (attempt === 1) {
          throw new Error(`extraction failed after retry: ${String(error)}`);
        }
      }
    }

    throw new Error("extraction failed: unreachable");
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `pnpm vitest run tests/extractor.test.ts`
Expected: PASS — 4 tests

- [ ] **Step 5: Commit**

```bash
git add src/extract/extractor.ts tests/extractor.test.ts
git commit -m "feat: Ollama extractor with schema validation and single retry"
```

---

### Task 7: Identity scoring and resolution

> **This task carries a decision that belongs to you, not to the implementer.** `scoreCandidate` encodes how aggressively the bot merges two people. The tests below pin the behaviour the spec requires; the reference implementation satisfies them, but the weights are a starting point to tune against `resolution_log`, not a finished answer. See the note after Step 5.

**Files:**

- Create: `src/resolve/score.ts`, `src/resolve/resolver.ts`
- Test: `tests/resolve.test.ts`

**Interfaces:**

- Consumes: `PersonCandidate` (Task 5)
- Produces: `KnownPerson`, `ScoredMatch`, `scoreCandidate(candidate, known): ScoredMatch[]`, `Resolution`, `resolveIdentity(scored, bands): Resolution`, `DEFAULT_BANDS`

- [ ] **Step 1: Write the failing test**

`tests/resolve.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { scoreCandidate, type KnownPerson } from "../src/resolve/score.js";
import { DEFAULT_BANDS, resolveIdentity } from "../src/resolve/resolver.js";

const known: KnownPerson[] = [
  {
    id: 1,
    canonicalName: "Sarah Chen",
    aliases: ["Sarah"],
    company: "Acme Robotics",
    phone: null,
    email: null,
  },
  {
    id: 2,
    canonicalName: "Sarah Miller",
    aliases: ["Sarah"],
    company: null,
    phone: null,
    email: null,
  },
  {
    id: 3,
    canonicalName: "Marcus Webb",
    aliases: [],
    company: "Initech",
    phone: null,
    email: null,
  },
];

describe("scoreCandidate", () => {
  it("scores an exact full-name match highest", () => {
    const [top] = scoreCandidate(
      {
        name: "Sarah Chen",
        aliases: [],
        company: null,
        context: "",
        confidence: 0.9,
      },
      known,
    );
    expect(top?.personId).toBe(1);
    expect(top?.score).toBeGreaterThan(0.9);
  });

  it("scores an ambiguous first name in the middle band for both Sarahs", () => {
    const scored = scoreCandidate(
      {
        name: "Sarah",
        aliases: [],
        company: null,
        context: "",
        confidence: 0.8,
      },
      known,
    );
    const sarahs = scored.filter((s) => s.personId === 1 || s.personId === 2);
    expect(sarahs).toHaveLength(2);
    for (const s of sarahs) {
      expect(s.score).toBeGreaterThan(DEFAULT_BANDS.low);
      expect(s.score).toBeLessThan(DEFAULT_BANDS.high);
    }
  });

  it("lets a company match break the tie", () => {
    const [top] = scoreCandidate(
      {
        name: "Sarah",
        aliases: [],
        company: "Acme Robotics",
        context: "",
        confidence: 0.8,
      },
      known,
    );
    expect(top?.personId).toBe(1);
    expect(top?.reasons).toContain("company");
  });

  it("scores an unknown name below the low band", () => {
    const scored = scoreCandidate(
      {
        name: "Priya Raman",
        aliases: [],
        company: null,
        context: "",
        confidence: 0.9,
      },
      known,
    );
    expect(scored[0]?.score ?? 0).toBeLessThanOrEqual(DEFAULT_BANDS.low);
  });
});

describe("resolveIdentity", () => {
  it("matches when the top score clears the high band", () => {
    expect(
      resolveIdentity(
        [{ personId: 1, score: 0.95, reasons: ["name"] }],
        DEFAULT_BANDS,
      ),
    ).toEqual({ action: "match", personId: 1, score: 0.95 });
  });

  it("asks when the top score lands in the middle band", () => {
    const out = resolveIdentity(
      [
        { personId: 1, score: 0.6, reasons: ["alias"] },
        { personId: 2, score: 0.6, reasons: ["alias"] },
      ],
      DEFAULT_BANDS,
    );
    expect(out.action).toBe("ask");
  });

  it("asks when two candidates tie near the high band", () => {
    const out = resolveIdentity(
      [
        { personId: 1, score: 0.93, reasons: ["name"] },
        { personId: 2, score: 0.92, reasons: ["name"] },
      ],
      DEFAULT_BANDS,
    );
    expect(out.action).toBe("ask");
  });

  it("creates when nothing scores above the low band", () => {
    expect(
      resolveIdentity(
        [{ personId: 3, score: 0.1, reasons: [] }],
        DEFAULT_BANDS,
      ),
    ).toEqual({ action: "create" });
  });

  it("creates when there is nothing to compare against", () => {
    expect(resolveIdentity([], DEFAULT_BANDS)).toEqual({ action: "create" });
  });
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `pnpm vitest run tests/resolve.test.ts`
Expected: FAIL — cannot find module `../src/resolve/score.js`

- [ ] **Step 3: Write `src/resolve/score.ts`**

```ts
import type { PersonCandidate } from "../extract/schema.js";

export interface KnownPerson {
  id: number;
  canonicalName: string;
  aliases: string[];
  company: string | null;
  phone: string | null;
  email: string | null;
}

export interface ScoredMatch {
  personId: number;
  score: number;
  reasons: string[];
}

const norm = (value: string): string => value.trim().toLowerCase();

/**
 * Score a candidate against every known person.
 *
 * Weights are deliberately conservative: a bare first name must NOT reach the
 * auto-match band, because a false merge fuses two histories and is expensive
 * to unwind. Tune these against `resolution_log` once real data exists.
 */
export function scoreCandidate(
  candidate: PersonCandidate,
  known: KnownPerson[],
): ScoredMatch[] {
  const candidateName = norm(candidate.name);
  const candidateCompany = candidate.company ? norm(candidate.company) : null;

  const scored = known.map((person) => {
    const reasons: string[] = [];
    let score = 0;

    if (norm(person.canonicalName) === candidateName) {
      score += 0.95;
      reasons.push("exact-name");
    } else if (person.aliases.some((alias) => norm(alias) === candidateName)) {
      score += 0.55;
      reasons.push("alias");
    } else if (norm(person.canonicalName).startsWith(`${candidateName} `)) {
      score += 0.5;
      reasons.push("given-name");
    }

    if (
      score > 0 &&
      candidateCompany &&
      person.company &&
      norm(person.company) === candidateCompany
    ) {
      score += 0.4;
      reasons.push("company");
    }

    return { personId: person.id, score: Math.min(score, 1), reasons };
  });

  return scored.filter((s) => s.score > 0).sort((a, b) => b.score - a.score);
}
```

- [ ] **Step 4: Write `src/resolve/resolver.ts`**

```ts
import type { ScoredMatch } from "./score.js";

export interface Bands {
  high: number;
  low: number;
}

/** Cautious by default: uncertain cases become questions, never silent merges. */
export const DEFAULT_BANDS: Bands = { high: 0.9, low: 0.35 };

/** Two candidates within this distance of each other are treated as a tie. */
const TIE_MARGIN = 0.05;

export type Resolution =
  | { action: "match"; personId: number; score: number }
  | { action: "ask"; candidates: ScoredMatch[] }
  | { action: "create" };

export function resolveIdentity(
  scored: ScoredMatch[],
  bands: Bands,
): Resolution {
  const [top, second] = scored;
  if (!top || top.score <= bands.low) return { action: "create" };

  const contested =
    second !== undefined && top.score - second.score < TIE_MARGIN;
  if (contested) return { action: "ask", candidates: scored.slice(0, 3) };

  if (top.score >= bands.high) {
    return { action: "match", personId: top.personId, score: top.score };
  }

  return { action: "ask", candidates: scored.slice(0, 3) };
}
```

- [ ] **Step 5: Run the tests**

Run: `pnpm vitest run tests/resolve.test.ts`
Expected: PASS — 9 tests

> **Your call to make.** The reference weights above put a bare first name at
> 0.55 — inside the ask band, so "Sarah" always produces a question when two
> Sarahs exist. Raising it above 0.9 makes the bot quieter and eventually
> merges the wrong Sarah. `TIE_MARGIN` is the other lever: it forces a question
> whenever two people score close together, even above the high band. Adjust
> both once `resolution_log` shows how often each path fires in practice.

- [ ] **Step 6: Commit**

```bash
git add src/resolve tests/resolve.test.ts
git commit -m "feat: cautious identity scoring and three-way resolution"
```

---

### Task 8: OpenBrain client and repository

**Files:**

- Create: `src/store/client.ts`, `src/store/repository.ts`
- Test: `tests/repository.test.ts`

**Interfaces:**

- Consumes: `KnownPerson` (Task 7), `MemoryCandidate` (Task 5)
- Produces: `OpenBrainClient` with `post<T>()`/`get<T>()`, `Repository` interface, `HttpRepository` with `findPeople(userId)`, `upsertPerson()`, `captureMemory()`, `recordInteraction()`, `logResolution()`, `recordClarification()`

- [ ] **Step 1: Write the failing test**

`tests/repository.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import { OpenBrainClient } from "../src/store/client.js";
import { HttpRepository } from "../src/store/repository.js";

function jsonResponse(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("HttpRepository", () => {
  it("lists known people", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({
        people: [
          {
            id: 1,
            canonical_name: "Sarah Chen",
            aliases: ["Sarah"],
            company: "Acme",
            phone: null,
            email: null,
          },
        ],
      }),
    );
    const repo = new HttpRepository(
      new OpenBrainClient("http://ob", fetchImpl as unknown as typeof fetch),
    );
    const people = await repo.findPeople(1, true);
    expect(people[0]?.canonicalName).toBe("Sarah Chen");
    expect(people[0]?.aliases).toEqual(["Sarah"]);
  });

  it("scopes the people query to one owner", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({ people: [] }));
    const repo = new HttpRepository(
      new OpenBrainClient("http://ob", fetchImpl as unknown as typeof fetch),
    );
    await repo.findPeople(2, false);
    const url = String(fetchImpl.mock.calls[0]?.[0]);
    expect(url).toContain("user_id=2");
    // A group capture must not be able to match anyone's private record.
    expect(url).toContain("include_private=false");
  });

  it("captures a memory with explicit visibility", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({ id: 42 }));
    const repo = new HttpRepository(
      new OpenBrainClient("http://ob", fetchImpl as unknown as typeof fetch),
    );
    const id = await repo.captureMemory({
      content: "launch in August",
      userId: 1,
      personId: 7,
      category: "relationship",
      confidence: 0.8,
      visibility: "private",
      opId: "op-1",
    });
    expect(id).toBe(42);
    const body = JSON.parse(String(fetchImpl.mock.calls[0]?.[1]?.body));
    expect(body.visibility).toBe("private");
    expect(body.person_id).toBe(7);
  });

  it("throws a descriptive error on a non-2xx response", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({ detail: "boom" }, 500));
    const repo = new HttpRepository(
      new OpenBrainClient("http://ob", fetchImpl as unknown as typeof fetch),
    );
    await expect(repo.findPeople(1, true)).rejects.toThrow(/500/);
  });
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `pnpm vitest run tests/repository.test.ts`
Expected: FAIL — cannot find module `../src/store/client.js`

- [ ] **Step 3: Write `src/store/client.ts`**

```ts
/**
 * Every request is bounded. A hung socket never rejects, so it would never
 * reach the queue-on-failure path — the outage would silently eat writes
 * instead of deferring them.
 */
const REQUEST_TIMEOUT_MS = 15_000;

export class OpenBrainClient {
  constructor(
    private readonly baseUrl: string,
    private readonly fetchImpl: typeof fetch = fetch,
    private readonly token: string | null = null,
  ) {}

  private headers(): Record<string, string> {
    return {
      "content-type": "application/json",
      ...(this.token ? { authorization: `Bearer ${this.token}` } : {}),
    };
  }

  async post<T>(path: string, body: unknown): Promise<T> {
    const res = await this.fetchImpl(`${this.baseUrl}${path}`, {
      method: "POST",
      headers: this.headers(),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`openbrain ${path} responded ${res.status}`);
    return (await res.json()) as T;
  }

  async get<T>(path: string): Promise<T> {
    const res = await this.fetchImpl(`${this.baseUrl}${path}`, {
      headers: this.headers(),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (!res.ok) throw new Error(`openbrain ${path} responded ${res.status}`);
    return (await res.json()) as T;
  }
}
```

- [ ] **Step 4: Write `src/store/repository.ts`**

```ts
import type { KnownPerson } from "../resolve/score.js";
import type { OpenBrainClient } from "./client.js";

export type Visibility = "shared" | "private";

export interface MemoryInput {
  content: string;
  userId: number;
  personId: number | null;
  category: string;
  confidence: number;
  visibility: Visibility;
  opId: string;
}

export interface InteractionInput {
  personId: number;
  occurredAt: Date;
  channel: string;
  summary: string;
  rawExcerpt: string;
  capturedBy: number;
  /** Everyone who spoke in the batch, not just `capturedBy`. */
  participants: number[];
  thoughtId: number | null;
  status: "extracted" | "unextracted";
  opId: string;
}

export interface ResolutionLogInput {
  candidateName: string;
  chosenPersonId: number | null;
  score: number | null;
  action: "auto_match" | "asked" | "created";
  opId: string;
}

/**
 * A question the bot must ask before it can safely store something. `context`
 * carries the memories held back pending the answer, so an ambiguous name
 * defers the write instead of discarding it.
 */
export interface UpsertPersonInput {
  userId: number;
  canonicalName: string;
  aliases: string[];
  company: string | null;
  firstMetContext: string | null;
  /** `shared` for group discoveries, `private` for DM ones. */
  visibility: Visibility;
  opId: string;
}

export interface ClarificationInput {
  askedUserId: number;
  kind: "identity" | "ownership" | "fact" | "viewpoint";
  question: string;
  context: {
    candidateName: string;
    candidatePersonIds: number[];
    heldMemories: { content: string; category: string; confidence: number }[];
    visibility: Visibility;
  };
  opId: string;
}

export interface Repository {
  /**
   * `includePrivate: false` returns only shared people — the correct scope for a
   * GROUP capture, which must not match (and then attach shared content to)
   * anybody's private record. A DM capture passes true to also see its own
   * user's private people, never the other user's.
   */
  findPeople(userId: number, includePrivate: boolean): Promise<KnownPerson[]>;
  /**
   * Writes return `null` when the backend was unreachable and the operation was
   * queued instead. The null is deliberately in the type: an implementation
   * that cast it away would let the pipeline report success for data that never
   * reached the database.
   */
  upsertPerson(input: UpsertPersonInput): Promise<number | null>;
  captureMemory(input: MemoryInput): Promise<number | null>;
  recordInteraction(input: InteractionInput): Promise<number | null>;
  logResolution(input: ResolutionLogInput): Promise<void>;
  recordClarification(input: ClarificationInput): Promise<number | null>;
}

interface PersonRow {
  id: number;
  canonical_name: string;
  aliases: string[] | null;
  company: string | null;
  phone: string | null;
  email: string | null;
}

export class HttpRepository implements Repository {
  constructor(private readonly client: OpenBrainClient) {}

  /**
   * Scoped to one owner. Unscoped, a person created privately in a DM could be
   * matched — and then written to — from a group capture, leaking the existence
   * of private records across the visibility boundary the design rests on.
   */
  async findPeople(
    userId: number,
    includePrivate: boolean,
  ): Promise<KnownPerson[]> {
    const { people } = await this.client.get<{ people: PersonRow[] }>(
      `/people?user_id=${encodeURIComponent(String(userId))}` +
        `&include_private=${includePrivate ? "true" : "false"}`,
    );
    return people.map((row) => ({
      id: row.id,
      canonicalName: row.canonical_name,
      aliases: row.aliases ?? [],
      company: row.company,
      phone: row.phone,
      email: row.email,
    }));
  }

  /**
   * Genuinely upserts. `opId` makes the write idempotent so a queue replay of a
   * request whose response was lost cannot create a duplicate person.
   */
  async upsertPerson(input: UpsertPersonInput): Promise<number> {
    const { id } = await this.client.post<{ id: number }>("/people", {
      user_id: input.userId,
      canonical_name: input.canonicalName,
      aliases: input.aliases,
      company: input.company,
      first_met_context: input.firstMetContext,
      visibility: input.visibility,
      op_id: input.opId,
    });
    return id;
  }

  async captureMemory(input: MemoryInput): Promise<number> {
    const { id } = await this.client.post<{ id: number }>("/capture", {
      content: input.content,
      user_id: input.userId,
      person_id: input.personId,
      category: input.category,
      confidence: input.confidence,
      visibility: input.visibility,
      source: "whatsapp",
      op_id: input.opId,
    });
    return id;
  }

  async recordInteraction(input: InteractionInput): Promise<number> {
    const { id } = await this.client.post<{ id: number }>("/interactions", {
      person_id: input.personId,
      occurred_at: input.occurredAt.toISOString(),
      channel: input.channel,
      summary: input.summary,
      raw_excerpt: input.rawExcerpt,
      captured_by: input.capturedBy,
      participants: input.participants,
      thought_id: input.thoughtId,
      status: input.status,
      op_id: input.opId,
    });
    return id;
  }

  async logResolution(input: ResolutionLogInput): Promise<void> {
    await this.client.post("/resolution-log", {
      candidate_name: input.candidateName,
      chosen_person_id: input.chosenPersonId,
      score: input.score,
      action: input.action,
      op_id: input.opId,
    });
  }

  async recordClarification(input: ClarificationInput): Promise<number | null> {
    const { id } = await this.client.post<{ id: number }>("/clarifications", {
      asked_user_id: input.askedUserId,
      kind: input.kind,
      question: input.question,
      context: input.context,
      op_id: input.opId,
    });
    return id;
  }
}
```

- [ ] **Step 5: Run the tests**

Run: `pnpm vitest run tests/repository.test.ts`
Expected: PASS — 4 tests

- [ ] **Step 6: Commit**

```bash
git add src/store tests/repository.test.ts
git commit -m "feat: OpenBrain HTTP client and repository"
```

> **Note for the implementer:** `/people`, `/interactions`, and `/resolution-log`
> do not exist in openbrain-mcp yet. Task 11 covers adding them. The repository
> is written against the contract first so the shape is settled before the
> Python side is touched.

---

### Task 9: Write-ahead queue

**Files:**

- Create: `src/store/queue.ts`, `src/store/queued-repository.ts`
- Test: `tests/queue.test.ts`

**Interfaces:**

- Consumes: `Repository`, `MemoryInput`, `InteractionInput`, `ResolutionLogInput` (Task 8)
- Produces: `PendingOp`, `WriteAheadQueue` with `enqueue(op)`, `drain(handler)`, `size()`; `QueuedRepository` implementing `Repository` plus `replay(): Promise<number>`

- [ ] **Step 1: Write the failing test**

`tests/queue.test.ts`:

```ts
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { WriteAheadQueue } from "../src/store/queue.js";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "prmm-q-"));
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

describe("WriteAheadQueue", () => {
  it("replays enqueued operations in order", async () => {
    const q = new WriteAheadQueue(dir);
    await q.enqueue({ kind: "captureMemory", payload: { n: 1 }, opId: "a" });
    await q.enqueue({ kind: "captureMemory", payload: { n: 2 }, opId: "b" });

    const seen: unknown[] = [];
    const drained = await q.drain(async (op) => {
      seen.push(op.payload);
    });

    expect(drained).toBe(2);
    expect(seen).toEqual([{ n: 1 }, { n: 2 }]);
    expect(await q.size()).toBe(0);
  });

  it("survives a process restart", async () => {
    await new WriteAheadQueue(dir).enqueue({
      kind: "captureMemory",
      payload: { n: 7 },
      opId: "c",
    });
    const reopened = new WriteAheadQueue(dir);
    expect(await reopened.size()).toBe(1);
  });

  it("keeps operations queued when the handler throws", async () => {
    const q = new WriteAheadQueue(dir);
    await q.enqueue({ kind: "captureMemory", payload: { n: 1 }, opId: "a" });
    await expect(
      q.drain(async () => {
        throw new Error("openbrain down");
      }),
    ).rejects.toThrow(/openbrain down/);
    expect(await q.size()).toBe(1);
  });

  it("drops the replayed prefix when the handler fails midway", async () => {
    const q = new WriteAheadQueue(dir);
    await q.enqueue({ kind: "captureMemory", payload: { n: 1 }, opId: "a" });
    await q.enqueue({ kind: "captureMemory", payload: { n: 2 }, opId: "b" });

    const handler = vi
      .fn()
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error("down"));

    await expect(q.drain(handler)).rejects.toThrow(/down/);
    expect(await q.size()).toBe(1);
  });
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `pnpm vitest run tests/queue.test.ts`
Expected: FAIL — cannot find module `../src/store/queue.js`

- [ ] **Step 3: Write `src/store/queue.ts`**

```ts
import {
  appendFile,
  chmod,
  mkdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";

export interface PendingOp {
  kind: string;
  payload: unknown;
  /** Stable id so a replay of a request whose response was lost is a no-op. */
  opId: string;
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;

/**
 * Revive Dates on the way out of JSON.
 *
 * `JSON.stringify` turns a Date into a string. Without this the replayed
 * payload carries strings where `Date` is declared, so `occurredAt.toISOString()`
 * throws on every replay — the op never drains and head-of-line blocks every
 * write queued behind it, permanently.
 */
const DATE_KEYS = new Set(["closedAt", "timestamp", "occurredAt"]);

function reviveDates(key: string, value: unknown): unknown {
  // Keyed, not blanket: a memory whose content happens to look like a timestamp
  // must stay a string, or it violates its declared type on replay.
  return DATE_KEYS.has(key) && typeof value === "string" && ISO_DATE.test(value)
    ? new Date(value)
    : value;
}

export class WriteAheadQueue {
  private readonly file: string;
  private readonly claim: string;
  private inFlight?: Promise<number>;

  constructor(private readonly dir: string) {
    this.file = join(dir, "pending.jsonl");
    this.claim = join(dir, "draining.jsonl");
  }

  private async ensure(): Promise<void> {
    await mkdir(this.dir, { recursive: true, mode: 0o700 });
    // mkdir's mode is ignored when the directory already exists, and this
    // directory holds plaintext PRIVATE memory content awaiting replay.
    await chmod(this.dir, 0o700);
  }

  private async read(path: string): Promise<PendingOp[]> {
    if (!existsSync(path)) return [];
    const raw = await readFile(path, "utf8");
    const ops: PendingOp[] = [];
    for (const line of raw.split("\n")) {
      if (!line) continue;
      try {
        ops.push(JSON.parse(line, reviveDates) as PendingOp);
      } catch {
        // A crash mid-append leaves a partial line. Throwing here would make
        // every later read fail and strand the whole queue permanently, so drop
        // the torn record loudly and keep the rest recoverable.
        console.error(
          `discarding corrupt queue line in ${path}: ${line.slice(0, 120)}`,
        );
      }
    }
    return ops;
  }

  async enqueue(op: PendingOp): Promise<void> {
    await this.ensure();
    await appendFile(this.file, `${JSON.stringify(op)}\n`, "utf8");
  }

  async size(): Promise<number> {
    const [pending, claimed] = await Promise.all([
      this.read(this.file),
      this.read(this.claim),
    ]);
    return pending.length + claimed.length;
  }

  /**
   * Replay every queued operation, oldest first.
   *
   * Concurrency is handled by *claiming*, not by rewriting in place. The pending
   * log is `rename`d to a claim file — atomic on POSIX — so writers immediately
   * begin a fresh log that a drain can never truncate. Rewriting the live file
   * from a snapshot, however carefully offset, always leaves a window where a
   * concurrent append is clobbered.
   *
   * A handler that throws leaves its remaining ops in the claim file, which the
   * next drain processes ahead of newly claimed work, preserving order.
   */
  async drain(handler: (op: PendingOp) => Promise<void>): Promise<number> {
    this.inFlight = (this.inFlight ?? Promise.resolve(0)).then(
      () => this.drainOnce(handler),
      () => this.drainOnce(handler),
    );
    return this.inFlight;
  }

  private async drainOnce(
    handler: (op: PendingOp) => Promise<void>,
  ): Promise<number> {
    await this.ensure();

    // Fold leftovers from a previously failed drain in front of new work.
    const leftover = await this.read(this.claim);
    if (existsSync(this.file)) {
      const pending = await readFile(this.file, "utf8");
      await rm(this.file, { force: true });
      await writeFile(
        this.claim,
        leftover.map((op) => `${JSON.stringify(op)}\n`).join("") + pending,
        "utf8",
      );
    }

    const ops = await this.read(this.claim);
    if (ops.length === 0) {
      await rm(this.claim, { force: true });
      return 0;
    }

    let completed = 0;
    try {
      for (const op of ops) {
        await handler(op);
        completed += 1;
      }
    } finally {
      const remaining = ops.slice(completed);
      if (remaining.length === 0) {
        await rm(this.claim, { force: true });
      } else {
        await writeFile(
          this.claim,
          remaining.map((op) => `${JSON.stringify(op)}\n`).join(""),
          "utf8",
        );
      }
    }

    return completed;
  }
}
```

- [ ] **Step 4: Write the failing test for the queued repository**

A queue nothing calls is dead code. `QueuedRepository` decorates `Repository`,
absorbs write failures into the queue, and replays them later.

Append to `tests/queue.test.ts`:

```ts
import { QueuedRepository } from "../src/store/queued-repository.js";
import type { Repository } from "../src/store/repository.js";

function repo(overrides: Partial<Repository> = {}): Repository {
  return {
    findPeople: vi.fn(async () => []),
    upsertPerson: vi.fn(async () => 10),
    captureMemory: vi.fn(async () => 20),
    recordInteraction: vi.fn(async () => 30),
    logResolution: vi.fn(async () => undefined),
    recordClarification: vi.fn(async () => 40),
    ...overrides,
  };
}

const MEMORY = {
  content: "x",
  userId: 1,
  personId: 2,
  category: "relationship",
  confidence: 0.9,
  visibility: "shared" as const,
  opId: "op-1",
};

function wrap(inner: Repository, dir: string): QueuedRepository {
  return new QueuedRepository(
    inner,
    new WriteAheadQueue(`${dir}/writes`),
    new WriteAheadQueue(`${dir}/quarantine`),
  );
}

describe("QueuedRepository", () => {
  it("passes writes straight through when the inner repository succeeds", async () => {
    const q = new WriteAheadQueue(`${dir}/writes`);
    const wrapped = wrap(repo(), dir);

    expect(await wrapped.captureMemory(MEMORY)).toBe(20);
    expect(await q.size()).toBe(0);
  });

  it("queues the write when the inner repository fails transiently", async () => {
    const wrapped = wrap(
      repo({
        captureMemory: vi.fn(async () => {
          throw new Error("ECONNREFUSED");
        }),
      }),
      dir,
    );

    expect(await wrapped.captureMemory(MEMORY)).toBeNull();
    expect(await new WriteAheadQueue(`${dir}/writes`).size()).toBe(1);
  });

  it("quarantines a permanently-rejected write instead of queueing it", async () => {
    // Retrying a 4xx never succeeds; queueing it would stall every write behind it.
    const wrapped = wrap(
      repo({
        captureMemory: vi.fn(async () => {
          throw new Error("openbrain /capture responded 422");
        }),
      }),
      dir,
    );

    expect(await wrapped.captureMemory(MEMORY)).toBeNull();
    expect(await new WriteAheadQueue(`${dir}/writes`).size()).toBe(0);
    expect(await new WriteAheadQueue(`${dir}/quarantine`).size()).toBe(1);
  });

  it("replays a queued interaction with its Date intact", async () => {
    // JSON turns Date into string; unrevived, occurredAt.toISOString() throws
    // on every replay and blocks the queue forever.
    let seen: unknown;
    const recordInteraction = vi
      .fn()
      .mockRejectedValueOnce(new Error("ECONNREFUSED"))
      .mockImplementationOnce(async (input: { occurredAt: unknown }) => {
        seen = input.occurredAt;
        return 30;
      });

    const wrapped = wrap(repo({ recordInteraction }), dir);
    await wrapped.recordInteraction({
      personId: 1,
      occurredAt: new Date("2026-07-26T12:00:00Z"),
      channel: "group",
      summary: "s",
      rawExcerpt: "r",
      capturedBy: 1,
      participants: [1, 2],
      thoughtId: null,
      status: "extracted",
      opId: "op-2",
    });

    expect(await wrapped.replay()).toBe(1);
    expect(seen).toBeInstanceOf(Date);
  });

  it("replays queued writes against the inner repository", async () => {
    const captureMemory = vi
      .fn()
      .mockRejectedValueOnce(new Error("down"))
      .mockResolvedValueOnce(99);
    const q = new WriteAheadQueue(`${dir}/writes`);
    const wrapped = wrap(repo({ captureMemory }), dir);

    await wrapped.captureMemory(MEMORY);
    expect(await q.size()).toBe(1);
    expect(await wrapped.replay()).toBe(1);
    expect(await q.size()).toBe(0);
  });

  it("never queues reads — a failed findPeople must surface", async () => {
    const wrapped = wrap(
      repo({
        findPeople: vi.fn(async () => {
          throw new Error("down");
        }),
      }),
      dir,
    );
    await expect(wrapped.findPeople(1, true)).rejects.toThrow(/down/);
  });
});
```

- [ ] **Step 5: Run the test and confirm it fails**

Run: `pnpm vitest run tests/queue.test.ts`
Expected: FAIL — cannot find module `../src/store/queued-repository.js`

- [ ] **Step 6: Write `src/store/queued-repository.ts`**

```ts
import type { PendingOp, WriteAheadQueue } from "./queue.js";
import type {
  ClarificationInput,
  InteractionInput,
  MemoryInput,
  Repository,
  ResolutionLogInput,
  UpsertPersonInput,
} from "./repository.js";
import type { KnownPerson } from "../resolve/score.js";

/**
 * A 4xx is the server rejecting the payload; replaying it fails forever and
 * head-of-line blocks every write behind it. Only transient faults may queue.
 */
function isPermanent(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /responded 4\d\d/.test(message);
}

type WriteKind =
  | "captureMemory"
  | "recordInteraction"
  | "logResolution"
  | "recordClarification"
  | "upsertPerson";

/**
 * Absorbs write failures into the write-ahead queue and returns null instead of
 * throwing, so a transient OpenBrain outage degrades to "stored later" rather
 * than losing the memory. Reads deliberately still throw: serving a caller an
 * empty person list would cause duplicate people, which is worse than failing.
 */
export class QueuedRepository implements Repository {
  constructor(
    private readonly inner: Repository,
    private readonly queue: WriteAheadQueue,
    /** Dead-letter store for ops no handler recognises. */
    private readonly quarantine: WriteAheadQueue,
  ) {}

  private async write<T>(
    kind: WriteKind,
    payload: { opId: string },
    run: () => Promise<T>,
  ): Promise<T | null> {
    try {
      return await run();
    } catch (error: unknown) {
      const op = { kind, payload, opId: payload.opId };
      if (isPermanent(error)) {
        // Retrying a rejected payload never succeeds; queueing it would stall
        // every legitimate write behind it.
        console.error(`quarantining permanently-failed ${kind} (${payload.opId})`, error);
        await this.quarantine.enqueue(op);
      } else {
        await this.queue.enqueue(op);
      }
      return null;
    }
  }

  findPeople(userId: number, includePrivate: boolean): Promise<KnownPerson[]> {
    return this.inner.findPeople(userId, includePrivate);
  }

  /**
   * Returns null when the write was queued. Throwing here would abandon every
   * other candidate and memory in the same batch, so the decision belongs to
   * the caller.
   */
  upsertPerson(input: UpsertPersonInput): Promise<number | null> {
    return this.write("upsertPerson", input, () =>
      this.inner.upsertPerson(input),
    );
  }

  captureMemory(input: MemoryInput): Promise<number | null> {
    return this.write("captureMemory", input, () =>
      this.inner.captureMemory(input),
    );
  }

  recordInteraction(input: InteractionInput): Promise<number | null> {
    return this.write("recordInteraction", input, () =>
      this.inner.recordInteraction(input),
    );
  }

  recordClarification(input: ClarificationInput): Promise<number | null> {
    return this.write("recordClarification", input, () =>
      this.inner.recordClarification(input),
    );
  }

  async logResolution(input: ResolutionLogInput): Promise<void> {
    await this.write("logResolution", input, () =>
      this.inner.logResolution(input),
    );
  }

  /**
   * Replay everything queued. Throws if the backend is still down.
   *
   * An unrecognised op is quarantined rather than thrown. `drain()` aborts on
   * the first handler error and only drops the completed prefix, so throwing
   * here would let one bad entry block replay of every legitimate write behind
   * it — forever. Poison must leave the queue.
   */
  replay(): Promise<number> {
    return this.queue.drain(async (op) => {
      try {
        await this.dispatch(op);
      } catch (error: unknown) {
        // A payload the server now rejects will be rejected forever. Left in
        // place it blocks every write behind it, so it must leave the queue.
        if (!isPermanent(error)) throw error;
        console.error(
          `quarantining permanently-failed replay ${op.kind} (${op.opId})`,
          error,
        );
        await this.quarantine.enqueue(op);
      }
    });
  }

  private async dispatch(op: PendingOp): Promise<void> {
    {
      switch (op.kind) {
        case "captureMemory":
          await this.inner.captureMemory(op.payload as MemoryInput);
          return;
        case "recordInteraction":
          await this.inner.recordInteraction(op.payload as InteractionInput);
          return;
        case "logResolution":
          await this.inner.logResolution(op.payload as ResolutionLogInput);
          return;
        case "recordClarification":
          await this.inner.recordClarification(op.payload as ClarificationInput);
          return;
        case "upsertPerson":
          await this.inner.upsertPerson(op.payload as UpsertPersonInput);
          return;
        default:
          console.error(
            `quarantining unknown queued operation: ${op.kind} (${op.opId})`,
          );
          await this.quarantine.enqueue(op);
          return;
      }
    }
  }
}
```

- [ ] **Step 7: Run the tests**

Run: `pnpm vitest run tests/queue.test.ts`
Expected: PASS — 10 tests

- [ ] **Step 8: Commit**

```bash
git add src/store/queue.ts src/store/queued-repository.ts tests/queue.test.ts
git commit -m "feat: write-ahead queue and queue-backed repository decorator"
```

---

### Task 10: Baileys transport session

**Files:**

- Create: `src/transport/session.ts`
- Test: `tests/session.test.ts`

**Interfaces:**

- Consumes: `Config` (Task 1), `normalizeMessage` (Task 3)
- Produces: `attachHandlers(sock, handlers)`, `WhatsAppSession` (constructor takes the message handler) with `start()`, `sendText(jid, text)`, `stop()`, `close()`

- [ ] **Step 1: Write the failing test**

`tests/session.test.ts`:

```ts
import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import { attachHandlers, type SocketLike } from "../src/transport/session.js";
import type { InboundMessage } from "../src/types.js";

function fakeSocket(): SocketLike & { ev: EventEmitter } {
  const ev = new EventEmitter();
  return {
    ev,
    sendMessage: vi.fn(async () => undefined),
  } as unknown as SocketLike & { ev: EventEmitter };
}

describe("attachHandlers", () => {
  it("emits normalised inbound messages", () => {
    const sock = fakeSocket();
    const seen: InboundMessage[] = [];
    attachHandlers(sock, {
      onMessage: (m) => seen.push(m),
      onReconnect: vi.fn(),
    });

    sock.ev.emit("messages.upsert", {
      type: "notify",
      messages: [
        {
          key: {
            id: "A1",
            remoteJid: "123@g.us",
            participant: "15555550100@s.whatsapp.net",
          },
          message: { conversation: "met Sarah" },
          messageTimestamp: 1785000000,
        },
      ],
    });

    expect(seen).toHaveLength(1);
    expect(seen[0]?.text).toBe("met Sarah");
  });

  it("ignores history syncs, keeping only live notifications", () => {
    const sock = fakeSocket();
    const seen: InboundMessage[] = [];
    attachHandlers(sock, {
      onMessage: (m) => seen.push(m),
      onReconnect: vi.fn(),
    });

    sock.ev.emit("messages.upsert", {
      type: "append",
      messages: [
        {
          key: { id: "A2", remoteJid: "123@g.us" },
          message: { conversation: "old message" },
        },
      ],
    });

    expect(seen).toHaveLength(0);
  });

  it("requests reconnect on a non-logout close", () => {
    const sock = fakeSocket();
    const onReconnect = vi.fn();
    attachHandlers(sock, { onMessage: vi.fn(), onReconnect });

    sock.ev.emit("connection.update", {
      connection: "close",
      lastDisconnect: { error: { output: { statusCode: 428 } } },
    });

    expect(onReconnect).toHaveBeenCalledWith(true);
  });

  it("does not reconnect after an explicit logout", () => {
    const sock = fakeSocket();
    const onReconnect = vi.fn();
    attachHandlers(sock, { onMessage: vi.fn(), onReconnect });

    sock.ev.emit("connection.update", {
      connection: "close",
      lastDisconnect: { error: { output: { statusCode: 401 } } },
    });

    expect(onReconnect).toHaveBeenCalledWith(false);
  });
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `pnpm vitest run tests/session.test.ts`
Expected: FAIL — cannot find module `../src/transport/session.js`

- [ ] **Step 3: Write `src/transport/session.ts`**

```ts
import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import makeWASocket, {
  DisconnectReason,
  fetchLatestBaileysVersion,
  makeCacheableSignalKeyStore,
  useMultiFileAuthState,
} from "baileys";
import { normalizeMessage, type WAMessageLike } from "./normalize.js";
import type { InboundMessage } from "../types.js";

export interface SocketLike {
  ev: { on(event: string, listener: (payload: never) => void): void };
  sendMessage(jid: string, content: { text: string }): Promise<unknown>;
}

export interface Handlers {
  onMessage: (message: InboundMessage) => void;
  onReconnect: (shouldReconnect: boolean) => void;
}

interface UpsertPayload {
  type: string;
  messages: WAMessageLike[];
}
interface ConnectionPayload {
  connection?: string;
  qr?: string;
  lastDisconnect?: { error?: { output?: { statusCode?: number } } };
}

export function attachHandlers(sock: SocketLike, handlers: Handlers): void {
  sock.ev.on("messages.upsert", ((payload: UpsertPayload) => {
    // "notify" is live traffic. "append" is history replay; ignoring it stops
    // a reconnect from re-extracting weeks of old conversation.
    if (payload.type !== "notify") return;
    for (const raw of payload.messages) {
      const message = normalizeMessage(raw);
      if (message) handlers.onMessage(message);
    }
  }) as (payload: never) => void);

  sock.ev.on("connection.update", ((update: ConnectionPayload) => {
    if (update.connection !== "close") return;
    const status = update.lastDisconnect?.error?.output?.statusCode;
    handlers.onReconnect(status !== DisconnectReason.loggedOut);
  }) as (payload: never) => void);
}

/**
 * Snapshot the credential file AFTER Baileys has written it.
 *
 * Two things this deliberately does NOT do: it does not re-serialise `creds`
 * itself (they contain binary key material that only survives
 * `BufferJSON.replacer`, and re-encoding them with plain `JSON.stringify`
 * silently corrupts the session so re-login fails), and it does not write
 * `creds.json` (that is `saveCreds`'s job — writing it too races the library).
 * It only keeps a known-good `.bak` to restore from.
 */
async function backupCreds(authDir: string): Promise<void> {
  const target = join(authDir, "creds.json");
  if (!existsSync(target)) return;
  const contents = await readFile(target, "utf8");
  if (!contents.trim()) return; // never overwrite a good backup with an empty one
  const backup = `${target}.bak`;
  await writeFile(`${backup}.tmp`, contents, "utf8");
  await rename(`${backup}.tmp`, backup);
}

const VERSION_FETCH_TIMEOUT_MS = 15_000;
const BASE_RECONNECT_MS = 3_000;
const MAX_RECONNECT_MS = 300_000;
const MAX_RECONNECT_ATTEMPTS = 10;

/** Minimal pino-shaped logger. Baileys calls .child() on whatever it is given. */
function silentLogger(): Record<string, unknown> {
  const noop = (): void => undefined;
  const logger: Record<string, unknown> = {
    level: "silent",
    trace: noop, debug: noop, info: noop, warn: noop, error: noop, fatal: noop,
  };
  logger.child = () => logger;
  return logger;
}

/**
 * Restore from `.bak` when `creds.json` is absent or empty. A backup nothing
 * reads is theatre; this is the path that makes writing one worthwhile.
 */
async function restoreCredsIfMissing(authDir: string): Promise<void> {
  const target = join(authDir, "creds.json");
  const backup = `${target}.bak`;
  if (!existsSync(backup)) return;
  const current = existsSync(target) ? await readFile(target, "utf8") : "";
  if (current.trim()) return;
  const saved = await readFile(backup, "utf8");
  if (!saved.trim()) return;
  console.warn("creds.json missing or empty — restoring from backup");
  await writeFile(target, saved, "utf8");
}

export class WhatsAppSession {
  private sock?: SocketLike & { sendMessage: SocketLike["sendMessage"] };
  private stopped = false;
  private attempts = 0;
  private reconnectTimer?: NodeJS.Timeout;

  constructor(
    private readonly authDir: string,
    private readonly onMessage: (message: InboundMessage) => void,
    private readonly onFatal: () => void = () => process.exit(1),
    private readonly onQr: (qr: string) => void = (qr) =>
      console.log("QR:", qr),
  ) {}

  async start(): Promise<void> {
    await mkdir(this.authDir, { recursive: true, mode: 0o700 });
    await chmod(this.authDir, 0o700);

    await restoreCredsIfMissing(this.authDir);
    const { state, saveCreds } = await useMultiFileAuthState(this.authDir);
    // Bounded: an unreachable version endpoint would otherwise hang start()
    // and every reconnect attempt indefinitely.
    const { version } = await Promise.race([
      fetchLatestBaileysVersion(),
      new Promise<never>((_, reject) =>
        setTimeout(
          () => reject(new Error("fetchLatestBaileysVersion timed out")),
          VERSION_FETCH_TIMEOUT_MS,
        ),
      ),
    ]);

    const sock = makeWASocket({
      version,
      auth: {
        creds: state.creds,
        // Baileys expects a pino-like logger with .child()/.trace(). Passing
        // `console` throws the first time its internals call logger.child().
        keys: makeCacheableSignalKeyStore(state.keys, silentLogger()),
      },
      browser: ["prmm-bot", "cli", "1.0.0"],
      syncFullHistory: false,
      markOnlineOnConnect: false,
    });

    this.sock = sock as unknown as SocketLike & {
      sendMessage: SocketLike["sendMessage"];
    };

    sock.ev.on("creds.update", () => {
      // An unhandled rejection here would silently lose the credential write
      // that keeps this session alive across restarts.
      void saveCreds()
        .then(() => backupCreds(this.authDir))
        .catch((error: unknown) =>
          console.error("failed persisting WhatsApp credentials", error),
        );
    });

    sock.ev.on("connection.update", (update) => {
      if (update.qr) this.onQr(update.qr);
      if (update.connection === "open") this.attempts = 0;
    });

    attachHandlers(this.sock, {
      onMessage: this.onMessage,
      onReconnect: (shouldReconnect) => {
        if (!shouldReconnect || this.stopped) return;
        if (this.attempts >= MAX_RECONNECT_ATTEMPTS) {
          // Staying alive but disconnected is the "dark with no signal" failure
          // this plan refuses elsewhere. Exit non-zero so a supervisor restarts
          // us and the operator sees it.
          console.error(
            `giving up after ${MAX_RECONNECT_ATTEMPTS} reconnect attempts; exiting`,
          );
          this.onFatal();
          return;
        }
        // Exponential backoff with a cap. A fixed 3s retry against a persistent
        // failure is a reconnect storm, which amplifies the ban risk this
        // project already carries.
        const delay = Math.min(
          BASE_RECONNECT_MS * 2 ** this.attempts,
          MAX_RECONNECT_MS,
        );
        this.attempts += 1;
        console.warn(`reconnecting in ${delay}ms (attempt ${this.attempts})`);
        this.reconnectTimer = setTimeout(() => {
          if (this.stopped) return;
          // start() can reject — a version fetch timing out is likeliest exactly
          // when connectivity is bad — and an unhandled rejection would crash
          // the process straight past this backoff policy.
          void this.start().catch((error: unknown) => {
            console.error("reconnect attempt failed", error);
          });
        }, delay);
      },
    });
  }

  async sendText(jid: string, text: string): Promise<void> {
    if (!this.sock) throw new Error("session not started");
    await this.sock.sendMessage(jid, { text });
  }

  stop(): void {
    this.stopped = true;
    // A pending reconnect would otherwise reopen the socket mid-shutdown.
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
  }

  /** Close the socket so the process can exit without a dangling connection. */
  async close(): Promise<void> {
    this.stopped = true;
    const sock = this.sock as { end?: (error?: Error) => void } | undefined;
    try {
      sock?.end?.(undefined);
    } catch (error: unknown) {
      console.error("error closing WhatsApp socket", error);
    }
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `pnpm vitest run tests/session.test.ts`
Expected: PASS — 4 tests

- [ ] **Step 5: Commit**

```bash
git add src/transport/session.ts tests/session.test.ts
git commit -m "feat: Baileys session with atomic creds and reconnect policy"
```

---

### Task 11: OpenBrain endpoints and end-to-end capture wiring

**Files:**

- Create: `src/pipeline.ts`, `src/index.ts`
- Modify: `~/Documents/Projects/openbrain/openbrain-mcp/tools/people.py` (create)
- Modify: `~/Documents/Projects/openbrain/openbrain-mcp/main.py` (register routes)
- Test: `tests/pipeline.test.ts`

**Interfaces:**

- Consumes: everything from Tasks 1–10
- Produces: `runCapture(batch, deps): Promise<CaptureOutcome>`, `main()`

> **Live infrastructure from here on.** Steps 1–3 need the openbrain-mcp
> checkout, a running server on :3000, migration 009 already applied (Task 2
> Step 5), and psql access. Export the environment first:
>
> ```bash
> set -a && . ./.env && set +a
> ```

- [ ] **Step 1: Verify the `/capture` contract before writing any client code**

`HttpRepository.captureMemory` posts `person_id`, `visibility`, `confidence`, and
`op_id` to the pre-existing `/capture` endpoint. **FastAPI silently drops fields a
Pydantic model does not declare.** If `/capture` has not been extended, visibility
— the invariant the whole design rests on — is discarded server-side while every
client test stays green, because they mock `fetch`.

```bash
cd ~/Documents/Projects/openbrain/openbrain-mcp
grep -n "class .*In\b" tools/capture.py
grep -rn "def fetch_all\|def fetch_one\|def execute" db.py
```

Read the request model. If it lacks `person_id`, `visibility`, or `op_id`, add
them in Step 2. Confirm the `db.py` helper names before using them below; adjust
the imports if they differ.

- [ ] **Step 2: Add the FastAPI endpoints the repository expects**

Create `tools/people.py` in openbrain-mcp:

```python
import json
from datetime import datetime

from fastapi import APIRouter
from pydantic import BaseModel
from db import fetch_all, fetch_one, execute

router = APIRouter()

# asyncpg binds jsonb from a JSON *string*, not a dict, unless a codec is
# registered. Passing the dict directly raises at runtime. If db.py already
# registers a json codec, drop the json.dumps calls below.


class PersonIn(BaseModel):
    user_id: int
    canonical_name: str
    aliases: list[str] = []
    company: str | None = None
    first_met_context: str | None = None
    visibility: str = "shared"
    op_id: str


class InteractionIn(BaseModel):
    person_id: int
    # datetime, not str: asyncpg will not coerce a string into TIMESTAMPTZ.
    occurred_at: datetime
    channel: str
    summary: str | None = None
    raw_excerpt: str | None = None
    captured_by: int
    participants: list[int] = []
    thought_id: int | None = None
    status: str = "extracted"
    op_id: str


class ResolutionIn(BaseModel):
    candidate_name: str
    chosen_person_id: int | None = None
    score: float | None = None
    action: str
    op_id: str


class ClarificationIn(BaseModel):
    asked_user_id: int
    kind: str
    question: str
    context: dict = {}
    op_id: str


async def _replay_guard(op_id: str) -> tuple[bool, int | None]:
    """Return (already_ran, prior_result_id).

    A write that committed but whose response was lost gets replayed from the
    bot's queue; without this guard the replay duplicates the row. The boolean
    is separate from the id because ops such as /resolution-log legitimately
    record a NULL result — keying on the id alone would report "never ran" and
    duplicate on every replay.
    """
    row = await fetch_one("SELECT result_id FROM write_ops WHERE op_id = $1", op_id)
    return (row is not None, row["result_id"] if row else None)


async def _remember(op_id: str, kind: str, result_id: int | None) -> None:
    await execute(
        "INSERT INTO write_ops (op_id, kind, result_id) VALUES ($1, $2, $3) "
        "ON CONFLICT (op_id) DO NOTHING",
        op_id, kind, result_id,
    )


@router.get("/people")
async def list_people(user_id: int, include_private: bool = False):
    """Shared people always; this user's private ones only when asked.

    Returning only `user_id`-owned rows would make whichever user does not own
    the shared pool duplicate every person. Returning private rows to a group
    capture would let shared content attach to a private record.
    """
    if include_private:
        rows = await fetch_all(
            "SELECT id, canonical_name, aliases, company, phone, email "
            "FROM people WHERE status = 'active' "
            "  AND (visibility = 'shared' OR user_id = $1) ORDER BY id",
            user_id,
        )
    else:
        rows = await fetch_all(
            "SELECT id, canonical_name, aliases, company, phone, email "
            "FROM people WHERE status = 'active' AND visibility = 'shared' "
            "ORDER BY id",
        )
    # dict(...) because asyncpg Records are not JSON-serialisable by default.
    return {"people": [dict(row) for row in rows]}


@router.post("/people")
async def create_person(body: PersonIn):
    ran, prior = await _replay_guard(body.op_id)
    if ran:
        return {"id": prior}

    # Genuinely upserts: a concurrent capture or a replay must not duplicate.
    # Two partial unique indexes exist, so the arbiter must match the row being
    # written. Using the shared index for a private row raises a unique violation
    # instead of upserting, and the queued replay then fails permanently.
    conflict = (
        "(lower(canonical_name)) WHERE status = 'active' AND visibility = 'shared'"
        if body.visibility == "shared"
        else "(user_id, lower(canonical_name)) "
             "WHERE status = 'active' AND visibility = 'private'"
    )
    row = await fetch_one(
        "INSERT INTO people "
        "(user_id, canonical_name, aliases, company, first_met_context, visibility) "
        "VALUES ($1, $2, $3, $4, $5, $6) "
        f"ON CONFLICT {conflict} "
        "DO UPDATE SET "
        "  aliases = (SELECT ARRAY(SELECT DISTINCT unnest(people.aliases || EXCLUDED.aliases))), "
        "  company = COALESCE(EXCLUDED.company, people.company), "
        "  first_met_context = COALESCE(people.first_met_context, EXCLUDED.first_met_context), "
        "  updated_at = NOW() "
        "RETURNING id",
        body.user_id, body.canonical_name, body.aliases, body.company,
        body.first_met_context, body.visibility,
    )
    await _remember(body.op_id, "upsertPerson", row["id"])
    return {"id": row["id"]}


@router.post("/interactions")
async def create_interaction(body: InteractionIn):
    ran, prior = await _replay_guard(body.op_id)
    if ran:
        return {"id": prior}
    row = await fetch_one(
        "INSERT INTO interactions "
        "(person_id, occurred_at, channel, summary, raw_excerpt, captured_by, "
        " participants, thought_id, status) "
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id",
        body.person_id, body.occurred_at, body.channel, body.summary,
        body.raw_excerpt, body.captured_by, body.participants,
        body.thought_id, body.status,
    )
    await _remember(body.op_id, "recordInteraction", row["id"])
    return {"id": row["id"]}


@router.post("/clarifications")
async def create_clarification(body: ClarificationIn):
    ran, prior = await _replay_guard(body.op_id)
    if ran:
        return {"id": prior}
    row = await fetch_one(
        "INSERT INTO clarifications (asked_user_id, kind, question, context) "
        "VALUES ($1, $2, $3, $4) RETURNING id",
        body.asked_user_id, body.kind, body.question, json.dumps(body.context),
    )
    await _remember(body.op_id, "recordClarification", row["id"])
    return {"id": row["id"]}


@router.post("/resolution-log")
async def log_resolution(body: ResolutionIn):
    ran, _ = await _replay_guard(body.op_id)
    if ran:
        return {"ok": True}
    await execute(
        "INSERT INTO resolution_log (candidate_name, chosen_person_id, score, action) "
        "VALUES ($1, $2, $3, $4)",
        body.candidate_name, body.chosen_person_id, body.score, body.action,
    )
    await _remember(body.op_id, "logResolution", None)
    return {"ok": True}
```

Register it in `main.py`. When `PRMM_OPENBRAIN_TOKEN` is set on the bot, the
server must actually verify it — a client that sends a bearer token to an
endpoint that never checks it is decorative, and these endpoints hold private
memory content.

```python
import os
from fastapi import Depends, Header, HTTPException

def require_token(authorization: str | None = Header(default=None)) -> None:
    expected = os.environ.get("OPENBRAIN_API_TOKEN")
    if not expected:
        return  # unauthenticated by deliberate choice; see the tracker gate
    if authorization != f"Bearer {expected}":
        raise HTTPException(status_code=401, detail="invalid token")

from tools import people
app.include_router(people.router, dependencies=[Depends(require_token)])
```

Then extend `/capture` itself. Step 1 established whether its request model
already accepts the new fields; if not, add them — this is the endpoint carrying
the visibility invariant, and FastAPI drops undeclared fields in silence.

```python
# tools/capture.py — add to the existing request model
class CaptureIn(BaseModel):
    # ... existing fields ...
    person_id: int | None = None
    visibility: str = "shared"
    confidence: float | None = None
    op_id: str | None = None
```

In the handler, apply the same replay guard and persist the association:

```python
from tools.people import _replay_guard, _remember

if body.op_id:
    ran, prior = await _replay_guard(body.op_id)
    if ran:
        return {"id": prior}

# ... existing insert, now including visibility/confidence ...

if body.person_id is not None:
    await execute(
        "INSERT INTO thought_people (thought_id, person_id) VALUES ($1, $2) "
        "ON CONFLICT DO NOTHING",
        thought_id, body.person_id,
    )
if body.op_id:
    await _remember(body.op_id, "captureMemory", thought_id)
```

Without the replay guard here, every queued `captureMemory` that replays creates
a duplicate thought — the idempotency exit criterion would hold for the new
endpoints while silently failing for the one that matters most.

- [ ] **Step 3: Confirm the endpoints round-trip before writing the client**

```bash
curl -sS -X POST localhost:3000/people -H 'content-type: application/json' \
  -d '{"user_id":1,"canonical_name":"Test Person","aliases":[],"op_id":"smoke-1"}'
# repeat the SAME command — the id must be identical, not a new row
curl -sS "localhost:3000/people?user_id=1" | head -c 400

# /capture must not silently drop the new fields
curl -sS -X POST localhost:3000/capture -H 'content-type: application/json' \
  -d '{"content":"smoke","user_id":1,"person_id":1,"visibility":"private","confidence":0.9,"op_id":"smoke-2"}'
psql "$PRMM_OPENBRAIN_DSN" -c "SELECT visibility FROM thoughts ORDER BY id DESC LIMIT 1;"
```

Expected: two identical ids, the person appearing exactly once, and the thought
reporting `private`. A second distinct id means the idempotency guard is not
working and every queue replay will duplicate data. A `shared` visibility means
`/capture` is dropping the field and the entire private-channel guarantee is
already broken.

- [ ] **Step 4: Write the failing test**

`tests/pipeline.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import { runCapture, type CaptureDeps } from "../src/pipeline.js";
import type { CaptureBatch } from "../src/capture/buffer.js";
import type { Repository } from "../src/store/repository.js";

function batch(
  text: string,
  route: CaptureBatch["route"] = { kind: "group", userId: 1 },
  participants = [1],
): CaptureBatch {
  return {
    route,
    participants,
    closedAt: new Date("2026-07-26T12:00:00Z"),
    messages: [
      {
        id: "m1",
        chatJid: "123@g.us",
        senderJid: "s@s.whatsapp.net",
        senderE164: "+15555550100",
        text,
        timestamp: new Date("2026-07-26T12:00:00Z"),
      },
    ],
  };
}

function repo(overrides: Partial<Repository> = {}): Repository {
  return {
    findPeople: vi.fn(async () => []),
    upsertPerson: vi.fn(async () => 10),
    captureMemory: vi.fn(async () => 20),
    recordInteraction: vi.fn(async () => 30),
    logResolution: vi.fn(async () => undefined),
    recordClarification: vi.fn(async () => 40),
    ...overrides,
  };
}

function stubQueue(): CaptureDeps["parkQueue"] {
  return {
    enqueue: vi.fn(async () => undefined),
  } as unknown as CaptureDeps["parkQueue"];
}

function person(name: string, confidence = 0.9) {
  return { name, aliases: [], company: null, context: "conf", confidence };
}

function memory(about: string, content: string, confidence = 0.8) {
  return { about, content, category: "relationship" as const, confidence };
}

function extractorOf(result: Partial<{
  people: ReturnType<typeof person>[];
  memories: ReturnType<typeof memory>[];
  commitments: unknown[];
  dates: unknown[];
}>) {
  return {
    extract: vi.fn(async () => ({
      people: result.people ?? [],
      memories: result.memories ?? [],
      commitments: result.commitments ?? [],
      dates: result.dates ?? [],
    })),
  };
}

describe("runCapture", () => {
  it("skips extraction entirely when the gate rejects the batch", async () => {
    const extractor = { extract: vi.fn() };
    const out = await runCapture(batch("lol ok"), {
      repo: repo(),
      extractor,
      parkQueue: stubQueue(),
      sharedOwnerUserId: 1,
      userIdForE164: () => 1,
    });
    expect(extractor.extract).not.toHaveBeenCalled();
    expect(out.status).toBe("skipped");
  });

  it("creates a person and captures a shared memory from the group", async () => {
    const r = repo();
    const out = await runCapture(batch("met Sarah Chen at the conference"), {
      repo: r,
      extractor: extractorOf({
        people: [person("Sarah Chen")],
        memories: [memory("Sarah Chen", "launch in August")],
      }),
      parkQueue: stubQueue(),
      sharedOwnerUserId: 1,
      userIdForE164: () => 1,
    });

    expect(out.status).toBe("stored");
    expect(r.upsertPerson).toHaveBeenCalledWith(
      expect.objectContaining({ firstMetContext: "conf" }),
    );
    expect(r.captureMemory).toHaveBeenCalledWith(
      expect.objectContaining({ visibility: "shared", personId: 10 }),
    );
  });

  it("marks DM-captured memories private", async () => {
    const r = repo();
    await runCapture(
      batch("skip Marcus Webb please", { kind: "dm", userId: 2 }, [2]),
      {
        repo: r,
        extractor: extractorOf({
          people: [person("Marcus Webb")],
          memories: [memory("Marcus Webb", "do not nudge me about him", 0.9)],
        }),
        parkQueue: stubQueue(),
        sharedOwnerUserId: 1,
        userIdForE164: () => 2,
      },
    );

    expect(r.captureMemory).toHaveBeenCalledWith(
      expect.objectContaining({ visibility: "private", userId: 2 }),
    );
  });

  it("parks the batch to the queue when extraction throws", async () => {
    const enqueue = vi.fn(async () => undefined);
    const extractor = {
      extract: vi.fn(async () => {
        throw new Error("model down");
      }),
    };
    const out = await runCapture(batch("met Sarah Chen at the conference"), {
      repo: repo(),
      extractor,
      parkQueue: { enqueue } as unknown as CaptureDeps["parkQueue"],
      sharedOwnerUserId: 1,
      userIdForE164: () => 1,
    });
    expect(out.status).toBe("parked");
    // A parked batch must stay recoverable; dropping it loses the conversation.
    expect(enqueue).toHaveBeenCalledWith(
      expect.objectContaining({ kind: "retryExtraction" }),
    );
  });

  it("parks the batch when the person lookup fails instead of duplicating everyone", async () => {
    const enqueue = vi.fn(async () => undefined);
    const r = repo({
      findPeople: vi.fn(async () => {
        throw new Error("openbrain down");
      }),
    });
    const out = await runCapture(batch("met Sarah Chen at the conference"), {
      repo: r,
      extractor: extractorOf({ people: [person("Sarah Chen")] }),
      parkQueue: { enqueue } as unknown as CaptureDeps["parkQueue"],
      sharedOwnerUserId: 1,
      userIdForE164: () => 1,
    });
    expect(out.status).toBe("parked");
    expect(r.upsertPerson).not.toHaveBeenCalled();
    expect(enqueue).toHaveBeenCalled();
  });

  it("reports degraded — not stored — when a write was only queued", async () => {
    // The smoke test reads this field. Saying "stored" while OpenBrain is down
    // would confirm persistence that never happened.
    const r = repo({ captureMemory: vi.fn(async () => null) });
    const out = await runCapture(batch("met Sarah Chen at the conference"), {
      repo: r,
      extractor: extractorOf({
        people: [person("Sarah Chen")],
        memories: [memory("Sarah Chen", "launch in August")],
      }),
      parkQueue: stubQueue(),
      sharedOwnerUserId: 1,
      userIdForE164: () => 1,
    });
    expect(out.status).toBe("degraded");
  });

  it("discards candidates below the confidence floor", async () => {
    const r = repo();
    const out = await runCapture(batch("maybe someone called Sarah Chen?"), {
      repo: r,
      extractor: extractorOf({ people: [person("Sarah Chen", 0.2)] }),
      parkQueue: stubQueue(),
      sharedOwnerUserId: 1,
      userIdForE164: () => 1,
    });
    expect(r.upsertPerson).not.toHaveBeenCalled();
    expect(out.people).toBe(0);
  });

  it("reuses a person created earlier in the same batch", async () => {
    // Two mentions of one new person must not create two rows.
    const r = repo();
    await runCapture(batch("met Sarah Chen, then Sarah Chen again"), {
      repo: r,
      extractor: extractorOf({
        people: [person("Sarah Chen"), person("Sarah Chen")],
      }),
      parkQueue: stubQueue(),
      sharedOwnerUserId: 1,
      userIdForE164: () => 1,
    });
    expect(r.upsertPerson).toHaveBeenCalledTimes(1);
  });

  it("matches a memory subject case-insensitively", async () => {
    const r = repo();
    const out = await runCapture(batch("met Sarah Chen at the conference"), {
      repo: r,
      extractor: extractorOf({
        people: [person("Sarah Chen")],
        memories: [memory("sarah chen", "launch in August")],
      }),
      parkQueue: stubQueue(),
      sharedOwnerUserId: 1,
      userIdForE164: () => 1,
    });
    expect(out.memories).toBe(1);
  });

  it("holds an unresolved memory on the clarification instead of dropping it", async () => {
    const r = repo({
      findPeople: vi.fn(async () => [
        { id: 1, canonicalName: "Sarah Chen", aliases: ["Sarah"], company: null, phone: null, email: null },
        { id: 2, canonicalName: "Sarah Miller", aliases: ["Sarah"], company: null, phone: null, email: null },
      ]),
    });
    const out = await runCapture(batch("saw Sarah at the conference"), {
      repo: r,
      extractor: extractorOf({
        people: [person("Sarah")],
        memories: [memory("Sarah", "launch in August")],
      }),
      parkQueue: stubQueue(),
      sharedOwnerUserId: 1,
      userIdForE164: () => 1,
    });

    expect(out.questions).toEqual(["Sarah"]);
    expect(r.recordClarification).toHaveBeenCalledWith(
      expect.objectContaining({
        kind: "identity",
        context: expect.objectContaining({
          heldMemories: [expect.objectContaining({ content: "launch in August" })],
        }),
      }),
    );
  });

  it("counts extracted commitments and dates as deferred rather than dropping them silently", async () => {
    const out = await runCapture(batch("met Sarah Chen at the conference"), {
      repo: repo(),
      extractor: extractorOf({
        people: [person("Sarah Chen")],
        commitments: [{ owner: "me", what: "send deck", due: null, confidence: 0.9 }],
        dates: [{ person: "Sarah Chen", kind: "launch", date: "2026-08-01", confidence: 0.9 }],
      }),
      parkQueue: stubQueue(),
      sharedOwnerUserId: 1,
      userIdForE164: () => 1,
    });
    // Phase 2 consumes these. Phase 1 must report them, never silently discard.
    expect(out.deferred).toEqual({ commitments: 1, dates: 1 });
  });
});
```

- [ ] **Step 5: Run the test and confirm it fails**

Run: `pnpm vitest run tests/pipeline.test.ts`
Expected: FAIL — cannot find module `../src/pipeline.js`

- [ ] **Step 6: Write `src/pipeline.ts`**

```ts
import type { CaptureBatch } from "./capture/buffer.js";
import type { Extractor } from "./extract/extractor.js";
import type { ExtractionResult } from "./extract/schema.js";
import { looksRelevant } from "./extract/gate.js";
import { DEFAULT_BANDS, resolveIdentity } from "./resolve/resolver.js";
import { scoreCandidate, type KnownPerson } from "./resolve/score.js";
import type { WriteAheadQueue } from "./store/queue.js";
import type { Repository, Visibility } from "./store/repository.js";

export interface CaptureDeps {
  repo: Repository;
  extractor: Extractor;
  /** Queue for batches whose extraction failed, replayed by index.ts. */
  parkQueue: WriteAheadQueue;
  /**
   * Owner for people discovered in the GROUP. Fixed, not derived from whoever
   * spoke first: `people` is owner-scoped and uniquely indexed per owner, so
   * speaker-order attribution would file the same third party under both users
   * and make lookups miss existing records.
   */
  sharedOwnerUserId: number;
  /** Maps a sender's E.164 back to a local user id, for question routing. */
  userIdForE164: (e164: string) => number | undefined;
}

export interface CaptureOutcome {
  /**
   * `degraded` means extraction succeeded but at least one write was queued
   * rather than persisted. It exists so the smoke test cannot read "stored"
   * while OpenBrain is down — a success signal for data that never landed.
   */
  status: "skipped" | "stored" | "degraded" | "parked";
  people: number;
  memories: number;
  questions: string[];
  /** Extracted but deliberately not stored in Phase 1. Never silently zero. */
  deferred: { commitments: number; dates: number };
}

/** Below this, a candidate is logged and discarded rather than written. */
const CONFIDENCE_FLOOR = 0.5;

const normalise = (value: string): string =>
  value.trim().toLowerCase().replace(/\s+/g, " ");

export async function runCapture(
  batch: CaptureBatch,
  deps: CaptureDeps,
): Promise<CaptureOutcome> {
  const joined = batch.messages.map((m) => m.text).join("\n");
  const empty = {
    people: 0,
    memories: 0,
    questions: [],
    deferred: { commitments: 0, dates: 0 },
  };

  if (!looksRelevant(joined)) return { status: "skipped", ...empty };

  const batchId = batch.messages[0]?.id ?? "unknown";
  const park = async (): Promise<CaptureOutcome> => {
    await deps.parkQueue.enqueue({
      kind: "retryExtraction",
      payload: batch,
      opId: `park:${batchId}`,
    });
    return { status: "parked", ...empty };
  };

  let extraction: ExtractionResult;
  try {
    extraction = await deps.extractor.extract(batch);
  } catch {
    return park();
  }

  // Ownership is the batch's channel, never its speaker order. A DM is owned by
  // its one participant; the group has a single fixed owner.
  // Ownership follows the channel, never speaker order. Group people are
  // `shared` under a fixed owner so BOTH users' lookups find them; DM people
  // are `private` to their one participant.
  const isDm = batch.route.kind === "dm";
  const userId = isDm ? batch.route.userId : deps.sharedOwnerUserId;

  const visibility: Visibility = isDm ? "private" : "shared";

  // Reads are never queued, so an outage here must park the batch rather than
  // proceed against an empty person list — which would duplicate everyone.
  let known: KnownPerson[];
  try {
    // Group captures see only the shared pool; DM captures also see their own.
    known = await deps.repo.findPeople(userId, isDm);
  } catch {
    return park();
  }

  const deferred = {
    commitments: extraction.commitments.length,
    dates: extraction.dates.length,
  };

  // Which participant actually mentioned a given name, for routing questions.
  const speakerFor = (name: string): number => {
    const needle = name.toLowerCase();
    const hit = batch.messages.find((m) => m.text.toLowerCase().includes(needle));
    const e164 = hit?.senderE164;
    const match = e164 ? deps.userIdForE164(e164) : undefined;
    return match ?? userId;
  };

  const nameToId = new Map<string, number>();
  const questions: string[] = [];
  const pendingNames = new Set<string>();
  const candidateIds = new Map<string, number[]>();
  const askedBy = new Map<string, number>();
  let degraded = false;

  for (const [index, candidate] of extraction.people.entries()) {
    if (candidate.confidence < CONFIDENCE_FLOOR) {
      console.warn(
        `dropping low-confidence person "${candidate.name}" (${candidate.confidence})`,
      );
      continue;
    }

    const opId = `${batchId}:person:${index}`;
    // Distinct namespace: sharing an op_id makes the resolution row hit the
    // person write's replay guard and never insert.
    const logOpId = `${batchId}:reslog:${index}`;
    const decision = resolveIdentity(
      scoreCandidate(candidate, known),
      DEFAULT_BANDS,
    );

    if (decision.action === "match") {
      nameToId.set(normalise(candidate.name), decision.personId);
      await deps.repo.logResolution({
        candidateName: candidate.name,
        chosenPersonId: decision.personId,
        score: decision.score,
        action: "auto_match",
        opId: logOpId,
      });
      continue;
    }

    if (decision.action === "ask") {
      questions.push(candidate.name);
      pendingNames.add(normalise(candidate.name));
      candidateIds.set(
        normalise(candidate.name),
        decision.candidates.map((c) => c.personId),
      );
      askedBy.set(normalise(candidate.name), speakerFor(candidate.name));
      await deps.repo.logResolution({
        candidateName: candidate.name,
        chosenPersonId: null,
        score: decision.candidates[0]?.score ?? null,
        action: "asked",
        opId: logOpId,
      });
      continue;
    }

    const id = await deps.repo.upsertPerson({
      userId,
      canonicalName: candidate.name,
      aliases: candidate.aliases,
      company: candidate.company,
      firstMetContext: candidate.context || null,
      visibility,
      opId,
    });

    if (id === null) {
      // Queued, so no id exists to anchor this person's memories. Park the whole
      // batch: continuing would silently drop every memory about them, and
      // throwing would abandon the candidates already resolved above.
      return park();
    }

    nameToId.set(normalise(candidate.name), id);
    // Newly created people must be visible to later candidates in the SAME
    // batch, or two mentions of one new person create two rows.
    known = [
      ...known,
      {
        id,
        canonicalName: candidate.name,
        aliases: candidate.aliases,
        company: candidate.company,
        phone: null,
        email: null,
      },
    ];
    await deps.repo.logResolution({
      candidateName: candidate.name,
      chosenPersonId: id,
      score: null,
      action: "created",
      opId: logOpId,
    });
  }

  let stored = 0;
  const held = new Map<
    string,
    { content: string; category: string; confidence: number }[]
  >();

  for (const [index, memory] of extraction.memories.entries()) {
    if (memory.confidence < CONFIDENCE_FLOOR) {
      console.warn(`dropping low-confidence memory about "${memory.about}"`);
      continue;
    }

    const key = normalise(memory.about);
    const personId = nameToId.get(key);

    if (personId === undefined) {
      // Subject unresolved. Hold the memory against the pending question so the
      // answer can complete it; never discard it silently.
      const bucket = held.get(key) ?? [];
      bucket.push({
        content: memory.content,
        category: memory.category,
        confidence: memory.confidence,
      });
      held.set(key, bucket);
      if (!pendingNames.has(key)) {
        console.warn(
          `memory subject "${memory.about}" matched no extracted person`,
        );
      }
      continue;
    }

    const opId = `${batchId}:memory:${index}`;
    const thoughtId = await deps.repo.captureMemory({
      content: memory.content,
      userId,
      personId,
      category: memory.category,
      confidence: memory.confidence,
      visibility,
      opId,
    });
    if (thoughtId === null) degraded = true;

    const interactionId = await deps.repo.recordInteraction({
      personId,
      occurredAt: batch.closedAt,
      channel: batch.route.kind,
      summary: memory.content,
      rawExcerpt: joined.slice(0, 2000),
      // The batch spans every participant; `participants` is the real record of
      // who spoke. capturedBy names the owner, not a speaker.
      capturedBy: userId,
      participants: batch.participants,
      thoughtId,
      status: "extracted",
      opId: `${batchId}:interaction:${index}`,
    });
    if (interactionId === null) degraded = true;

    stored += 1;
  }

  // Any held memory whose subject produced no question would otherwise vanish
  // (e.g. its person candidate fell below the confidence floor). Raise a
  // question for it so the content is preserved and answerable.
  for (const key of held.keys()) {
    if (!pendingNames.has(key)) {
      questions.push(key);
      pendingNames.add(key);
    }
  }

  // Persist every question, carrying the memories it is holding, so an
  // ambiguous name defers a write instead of destroying it.
  for (const [qIndex, name] of questions.entries()) {
    const key = normalise(name);
    const clarificationId = await deps.repo.recordClarification({
      // Ask whoever first mentioned the ambiguous name, not the nominal owner —
      // otherwise half the group's questions go to the wrong person's DM.
      askedUserId: askedBy.get(key) ?? userId,
      kind: "identity",
      question: `Which "${name}" do you mean?`,
      context: {
        candidateName: name,
        candidatePersonIds: candidateIds.get(key) ?? [],
        heldMemories: held.get(key) ?? [],
        visibility,
      },
      opId: `${batchId}:clarify:${qIndex}`,
    });
    if (clarificationId === null) degraded = true;
  }

  return {
    status: degraded ? "degraded" : "stored",
    people: nameToId.size,
    memories: stored,
    questions,
    deferred,
  };
}
```

- [ ] **Step 7: Run the tests**

Run: `pnpm vitest run tests/pipeline.test.ts`
Expected: PASS — 11 tests

- [ ] **Step 8: Write `src/index.ts`**

```ts
import { CaptureBuffer, type CaptureBatch } from "./capture/buffer.js";
import { loadConfig } from "./config.js";
import { OllamaExtractor } from "./extract/extractor.js";
import { runCapture } from "./pipeline.js";
import { OpenBrainClient } from "./store/client.js";
import { WriteAheadQueue } from "./store/queue.js";
import { QueuedRepository } from "./store/queued-repository.js";
import { HttpRepository } from "./store/repository.js";
import { routeMessage } from "./transport/router.js";
import { WhatsAppSession } from "./transport/session.js";

const REPLAY_INTERVAL_MS = 60_000;
// Must exceed EXTRACTION_TIMEOUT_MS (120s) — otherwise SIGTERM during an
// in-flight extraction exits before the batch can finish or be parked.
const SHUTDOWN_GRACE_MS = 150_000;

async function main(): Promise<void> {
  const cfg = loadConfig(process.env);

  // Three separate stores. Mixing repository writes with parked batches in one
  // queue lets an op no handler recognises block replay of everything behind it.
  const writeQueue = new WriteAheadQueue(`${cfg.queueDir}/writes`);
  const parkQueue = new WriteAheadQueue(`${cfg.queueDir}/parked`);
  const quarantine = new WriteAheadQueue(`${cfg.queueDir}/quarantine`);

  // Nothing drains quarantine automatically — these ops need a human. Surface
  // the depth so a dead-letter pile cannot accumulate unnoticed.
  const stuck = await quarantine.size();
  if (stuck > 0) {
    console.error(`${stuck} quarantined operations need manual review in ${cfg.queueDir}/quarantine`);
  }

  const repo = new QueuedRepository(
    new HttpRepository(
      new OpenBrainClient(cfg.openbrainUrl, fetch, cfg.openbrainToken),
    ),
    writeQueue,
    quarantine,
  );
  const extractor = new OllamaExtractor(cfg.ollamaUrl, cfg.ollamaModel);

  let accepting = true;
  const inFlight = new Set<Promise<unknown>>();
  const track = <T>(promise: Promise<T>): Promise<T> => {
    inFlight.add(promise);
    void promise.finally(() => inFlight.delete(promise));
    return promise;
  };

  const capture = (batch: CaptureBatch): Promise<void> =>
    runCapture(batch, {
      repo,
      extractor,
      parkQueue,
      sharedOwnerUserId: cfg.sharedOwnerUserId,
      userIdForE164: (e164) =>
        cfg.users.find((u) => u.e164 === e164)?.userId,
    })
      .then((out) => {
        console.log("capture", out);
        if (out.questions.length > 0) {
          console.warn(`pending clarifications: ${out.questions.join(", ")}`);
        }
      })
      .catch((error: unknown) => console.error("capture failed", error));

  // Drain both queues: writes stranded by an OpenBrain outage, and batches
  // parked when the extractor was down.
  const replay = async (): Promise<void> => {
    try {
      const drained = await repo.replay();
      if (drained > 0) console.log(`replayed ${drained} queued writes`);
    } catch {
      // Still down. The queue holds the work; try again next tick.
    }
    try {
      await parkQueue.drain(async (op) => {
        await capture(op.payload as CaptureBatch);
      });
    } catch (error: unknown) {
      console.error("park replay failed", error);
    }
  };

  await replay();
  const replayTimer = setInterval(() => void replay(), REPLAY_INTERVAL_MS);

  const buffer = new CaptureBuffer(cfg.debounceMs, (batch) => {
    void track(capture(batch));
  });

  const session = new WhatsAppSession(
    cfg.authDir,
    (message) => {
      if (!accepting) return;
      const route = routeMessage(message, cfg);
      if (route.kind === "ignore") {
        // An unresolved sender on OUR chat is an operational fault, not a
        // stranger. Staying quiet means the bot goes dark with no signal.
        if (route.reason === "unresolved-sender") {
          console.error(
            `unresolved sender on allowlisted chat: ${message.senderJid}`,
          );
        }
        return;
      }
      buffer.add(message, route);
    },
    // Exit non-zero so the supervisor restarts us rather than leaving the bot
    // alive but permanently disconnected.
    () => process.exit(1),
  );

  await session.start();

  let shuttingDown = false;
  const shutdown = async (): Promise<void> => {
    if (shuttingDown) return;
    shuttingDown = true;
    clearInterval(replayTimer);
    session.stop();
    // Stop admitting new traffic first; anything buffered after flushAll would
    // be dropped at exit.
    accepting = false;

    // Flush, then WAIT. Exiting immediately kills every in-flight extraction
    // and write, losing data on every intentional restart — exactly what the
    // write-ahead queue exists to prevent.
    buffer.flushAll();
    await Promise.race([
      Promise.allSettled([...inFlight]),
      new Promise((resolve) => setTimeout(resolve, SHUTDOWN_GRACE_MS)),
    ]);

    await session.close();
    process.exit(0);
  };

  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => void shutdown());
  }
}

void main();
```

- [ ] **Step 9: Run the whole suite**

Run: `pnpm test`
Expected: PASS — 79 tests across 11 files (config 5, migration 4, router 14, buffer 7, gate 7, extractor 4, resolve 9, repository 4, queue 10, session 4, pipeline 11)

- [ ] **Step 10: Commit**

```bash
git add src/pipeline.ts src/index.ts tests/pipeline.test.ts
git commit -m "feat: wire end-to-end capture pipeline"
```

- [ ] **Step 11: Manual smoke test**

Only after every spec prerequisite is settled — particularly the WhatsApp
number. Create a throwaway group with a second device, never a real one.

```bash
cp .env.example .env   # fill in real JIDs
pnpm dev               # scan the QR from WhatsApp > Linked Devices
```

Post `met Sarah Chen at the robotics conference, her launch is in August` into
the test group. Wait for the debounce window.

Expect a `capture` log line reading `status: "stored"`. **`"degraded"` means the
writes were only queued** — OpenBrain is unreachable and nothing was persisted;
fix that before trusting anything below. Then confirm against the database
rather than the log:

```bash
psql "$PRMM_OPENBRAIN_DSN" -c "SELECT canonical_name, first_met_context FROM people ORDER BY id DESC LIMIT 1;"
psql "$PRMM_OPENBRAIN_DSN" -c "SELECT content, visibility FROM thoughts ORDER BY id DESC LIMIT 1;"
psql "$PRMM_OPENBRAIN_DSN" -c "SELECT action, score FROM resolution_log ORDER BY id DESC LIMIT 1;"
```

Expected: `Sarah Chen` with a non-null context, a thought with
`visibility = shared`, and one `created` resolution row.

Then verify the DM path is genuinely private:

```bash
# send "remind me Marcus Webb is unreliable" to the bot in a 1:1 DM
psql "$PRMM_OPENBRAIN_DSN" -c "SELECT content, visibility FROM thoughts ORDER BY id DESC LIMIT 1;"
```

Expected: `visibility = private`. Anything else means DM content is reaching the
shared pool, and the channel's whole premise is broken.

---

## Phase 1 exit criteria

- `pnpm test` passes with no skipped tests
- The bot captures a group message into `people`, `thoughts`, and `interactions`
- A DM-captured memory lands with `visibility = 'private'`
- Killing OpenBrain mid-capture reports `status: "degraded"`, and the queued
  writes replay on restart without duplicating rows
- Killing Ollama mid-capture reports `status: "parked"`, and the batch is
  re-extracted on recovery
- POSTing the same `op_id` twice returns the same id and creates one row
- `SIGTERM` during an in-flight capture loses nothing
- A group with disappearing messages enabled still captures
- `resolution_log` records one row per person candidate above the confidence floor

Phase 2 — triggers, nudges, clarification delivery, and approval reactions —
gets its own plan once these hold.
