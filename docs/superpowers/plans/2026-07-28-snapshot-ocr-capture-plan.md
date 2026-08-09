# Snapshot Capture — OCR for Profiles, Badges, and Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** DM the bot an image (LinkedIn profile, badge, business card, programme bio) and have it OCR the text, extract a person, and store the result through the existing resolve/store/acknowledgement pipeline — the same way a typed message does today.

**Architecture:** Media survives `normalize`/`router` as a lightweight `MediaPayload` (mimetype + caption only — no bytes, no raw Baileys object); actual download happens on demand through a new `WhatsAppSession.downloadMedia`, since fetching from WhatsApp's CDN is inherently async and Baileys-specific. OCR (`ocr/`) and a second extraction prompt (`extract/snapshot-prompt.ts`) are new. Resolution (`resolve/`) and storage (`store/`) are reused unchanged by extracting `pipeline.ts`'s storage loop into a shared `storeExtraction` helper that both the existing transcript path and the new snapshot path call.

**Tech Stack:** TypeScript, Node.js, Vitest, Baileys 7.0.0-rc13, Postgres via `postgres.js`, Ollama (local extraction), macOS Vision framework via a Swift CLI script, tesseract 5.5.2 (fallback).

## Global Constraints

- One image per DM message, sent by either allowlisted user, own-DM only — a group image is ignored (spec: Scope).
- OCR: macOS Vision primary, tesseract 5.5.2 fallback — no new npm dependency (spec: OCR).
- Extraction output stays `ExtractionResultSchema`-shaped — no schema change (spec: Extraction).
- Snapshot captures set `visibility: 'shared'` on the person and any memory candidate — opposite of DM capture's `'private'` default (spec: Visibility).
- The acknowledgement always names the visibility default: `Read a profile for **{name}** — {context}. Saved as shared; {other user} can see this. Reply \`private\` to restrict it.` (spec: Visibility).
- `private` is matched as a bare-word DM reply against an in-memory, single-slot, per-`chatJid` map — not `clarifications`, not durable, cleared by any other message or a restart (spec: Visibility, and the plan's own Task 7).
- Every failure maps onto an existing `CaptureOutcome` status and existing reaction (📌/⚠️/🛑/🚫/❓) — no new status value (spec: Error handling).
- The stateful correction loop (`clarifications` as a draft store) is explicitly out of scope — Phase B (spec: Phase B).

---

## File Structure

| File                                   | Responsibility                                                                                              |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `src/types.ts` (modify)                | `MediaPayload` type; `InboundMessage.media`                                                                 |
| `src/transport/normalize.ts` (modify)  | Recognize `imageMessage`, populate `media`, relax the drop guard                                            |
| `src/transport/session.ts` (modify)    | Cache raw inbound messages briefly; `downloadMedia(id)` fetches bytes on demand                             |
| `src/transport/router.ts` (modify)     | `snapshot` route; a group image is `ignore`d, not silently mis-routed as a text capture                     |
| `src/ocr/vision.swift` (new)           | Swift CLI: Vision `VNRecognizeTextRequest` over an image path, prints recognized lines                      |
| `src/ocr/vision.ts` (new)              | Spawns `vision.swift`, returns its stdout                                                                   |
| `src/ocr/tesseract.ts` (new)           | Spawns `tesseract`, returns its stdout                                                                      |
| `src/ocr/index.ts` (new)               | `extractText(media)`: writes a temp file, tries Vision on macOS, falls back to tesseract                    |
| `src/extract/snapshot-prompt.ts` (new) | System + user prompt for OCR'd text, no speaker roster                                                      |
| `src/extract/extractor.ts` (modify)    | Share the retry/parse/validate loop between the transcript and snapshot prompts                             |
| `src/pipeline.ts` (modify)             | Extract `storeExtraction` from `runCapture`'s body; fix `aboutTheOther` to key off `visibility`, not `isDm` |
| `src/snapshot/state.ts` (new)          | In-memory single-slot "did a snapshot just land in this DM" map                                             |
| `src/snapshot/capture.ts` (new)        | `runSnapshotCapture`: OCR → extract → `storeExtraction` → acknowledgement text                              |
| `src/index.ts` (modify)                | Wire the `snapshot` route, the retry-park path, and the `private` reply                                     |

Each new module has one job. `ocr/` and `extract/snapshot-prompt.ts` know nothing about persistence; `snapshot/capture.ts` knows nothing about OCR internals or Baileys; `snapshot/state.ts` knows nothing about either — it is a plain map. This mirrors the existing split between `transport/`, `extract/`, `resolve/`, and `store/`.

---

### Task 1: Media survives `normalize.ts`

**Files:**

- Modify: `src/types.ts`
- Modify: `src/transport/normalize.ts`
- Test: `tests/router.test.ts` (existing `describe("normalizeMessage", ...)` block — that is where these tests already live; do not create a new file)

**Interfaces:**

- Produces: `export type MediaPayload = { mimetype: string; caption: string | null }` in `types.ts`; `InboundMessage.media?: MediaPayload`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/router.test.ts`, inside the existing `describe("normalizeMessage", ...)` block (after the last `it(...)`, before the closing `});`):

```ts
it("populates media for an image message with no text", () => {
  const out = normalizeMessage({
    key: {
      id: "A11",
      remoteJid: "15555550101@s.whatsapp.net",
      participant: "15555550101@s.whatsapp.net",
    },
    message: {
      imageMessage: { mimetype: "image/jpeg", caption: null },
    },
    messageTimestamp: 1785000000,
  });
  expect(out?.text).toBe("");
  expect(out?.media).toEqual({ mimetype: "image/jpeg", caption: null });
});

it("carries a caption on an image message into media.caption", () => {
  const out = normalizeMessage({
    key: {
      id: "A12",
      remoteJid: "15555550101@s.whatsapp.net",
      participant: "15555550101@s.whatsapp.net",
    },
    message: {
      imageMessage: { mimetype: "image/png", caption: "this is User B's new boss" },
    },
    messageTimestamp: 1785000000,
  });
  expect(out?.media?.caption).toBe("this is User B's new boss");
});

it("still drops a message with neither text nor media", () => {
  expect(
    normalizeMessage({
      key: { id: "A13", remoteJid: "123@g.us" },
      message: {},
      messageTimestamp: 1785000000,
    }),
  ).toBeNull();
});

it("leaves media undefined on an ordinary text message", () => {
  const out = normalizeMessage({
    key: {
      id: "A14",
      remoteJid: "123@g.us",
      participant: "15555550100@s.whatsapp.net",
    },
    message: { conversation: "met Sarah" },
    messageTimestamp: 1785000000,
  });
  expect(out?.media).toBeUndefined();
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm vitest run tests/router.test.ts -t normalizeMessage`
Expected: FAIL — `imageMessage` does not exist on `WAContent`, `media` is not read.

- [ ] **Step 3: Add `MediaPayload` to `types.ts`**

In `src/types.ts`, add after the `ChannelKind` export at the top:

```ts
/** Mimetype and caption only — no bytes. Downloading is async and Baileys-specific, so it happens on demand via `WhatsAppSession.downloadMedia`, not here. */
export type MediaPayload = { mimetype: string; caption: string | null };
```

In the `InboundMessage` interface, add one field after `text: string;`:

```ts
  text: string;
  /** Present only when this message carried an image. */
  media?: MediaPayload;
```

- [ ] **Step 4: Update `normalize.ts`**

In `src/transport/normalize.ts`, add `imageMessage` to the `WAContent` interface (after `documentWithCaptionMessage`):

```ts
  documentWithCaptionMessage?: { message?: WAContent | null } | null;
  imageMessage?: { mimetype?: string | null; caption?: string | null } | null;
```

Add the import:

```ts
import type { InboundMessage, MediaPayload } from "../types.js";
```

Replace the text-extraction and drop-guard block:

```ts
const content = unwrap(raw.message);
const text = content?.conversation ?? content?.extendedTextMessage?.text ?? "";
if (!text.trim()) return null;
```

with:

```ts
const content = unwrap(raw.message);
const text = content?.conversation ?? content?.extendedTextMessage?.text ?? "";
const media: MediaPayload | undefined = content?.imageMessage
  ? {
      mimetype: content.imageMessage.mimetype ?? "application/octet-stream",
      caption: content.imageMessage.caption ?? null,
    }
  : undefined;
if (!text.trim() && !media) return null;
```

Add `media` to the returned object, after `text,`:

```ts
    text,
    media,
    timestamp: new Date(toEpochSeconds(raw.messageTimestamp) * 1000),
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm vitest run tests/router.test.ts -t normalizeMessage`
Expected: PASS, all `normalizeMessage` cases green including the four new ones.

- [ ] **Step 6: Run the full suite and typecheck**

Run: `pnpm test`
Expected: PASS. `media` is optional so no existing call site breaks.

- [ ] **Step 7: Commit**

```bash
git add src/types.ts src/transport/normalize.ts tests/router.test.ts
git commit -m "feat: recognize imageMessage in normalize, carry mimetype/caption as media"
```

---

### Task 2: `WhatsAppSession.downloadMedia`

**Files:**

- Modify: `src/transport/session.ts`
- Test: `tests/session.test.ts`

**Interfaces:**

- Consumes: `InboundMessage` (Task 1); Baileys `downloadMediaMessage` from the `baileys` package (already a dependency).
- Produces: `WhatsAppSession.downloadMedia(id: string): Promise<Buffer>` — throws if `id` was never seen or has aged out of the cache.

Downloading needs the _original_ raw Baileys message (it carries the media key), not just the normalized `InboundMessage`. Rather than leak Baileys' proto shape into `types.ts`, `session.ts` keeps a short-lived cache of raw messages by id — it already sees every raw message in `attachHandlers`'s upsert loop — and looks one up when `downloadMedia` is called.

- [ ] **Step 1: Write the failing test**

Add to `tests/session.test.ts` (find the existing `describe("WhatsAppSession", ...)` or top-level block and add a new one; if the file constructs a fake `SocketLike` and drives it through `attachHandlers`, follow that same pattern):

```ts
import { downloadMediaMessage } from "baileys";

vi.mock("baileys", async (importOriginal) => {
  const actual = await importOriginal<typeof import("baileys")>();
  return { ...actual, downloadMediaMessage: vi.fn() };
});

describe("WhatsAppSession.downloadMedia", () => {
  it("downloads the raw message matching a seen id", async () => {
    vi.mocked(downloadMediaMessage).mockResolvedValue(Buffer.from("fake-jpeg"));

    const session = new WhatsAppSession("./auth-test");
    const rawMessage = {
      key: { id: "img1", remoteJid: "15555550101@s.whatsapp.net" },
      message: { imageMessage: { mimetype: "image/jpeg" } },
    };
    // Feed it through the same path attachHandlers uses in production.
    session.rememberRaw(rawMessage);

    const buf = await session.downloadMedia("img1");
    expect(buf.toString()).toBe("fake-jpeg");
    expect(downloadMediaMessage).toHaveBeenCalledWith(rawMessage, "buffer", {});
  });

  it("throws for an id it never saw", async () => {
    const session = new WhatsAppSession("./auth-test");
    await expect(session.downloadMedia("never-seen")).rejects.toThrow(
      /unknown message/,
    );
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm vitest run tests/session.test.ts -t downloadMedia`
Expected: FAIL — `rememberRaw` and `downloadMedia` do not exist on `WhatsAppSession`.

- [ ] **Step 3: Implement in `session.ts`**

Add the import at the top of `src/transport/session.ts`:

```ts
import {
  DisconnectReason,
  downloadMediaMessage,
  fetchLatestBaileysVersion,
  makeCacheableSignalKeyStore,
  useMultiFileAuthState,
} from "baileys";
```

Add a bounded cache and two methods to the `WhatsAppSession` class, right after the `attempts`/`reconnectTimer` private fields:

```ts
  /**
   * Raw messages seen recently, so `downloadMedia` can fetch bytes for one
   * without re-deriving Baileys' proto shape elsewhere. Bounded: an image
   * nobody downloads (every group image, most DM images the user never
   * revisits) must not leak memory over a long-running process.
   */
  private readonly recentRaw = new Map<string, WAMessageLike>();
  private static readonly RAW_CACHE_LIMIT = 200;

  /** Called from the `messages.upsert` handler for every raw message seen. */
  rememberRaw(raw: WAMessageLike): void {
    const id = raw.key.id;
    if (!id) return;
    if (this.recentRaw.size >= WhatsAppSession.RAW_CACHE_LIMIT) {
      const oldest = this.recentRaw.keys().next().value;
      if (oldest !== undefined) this.recentRaw.delete(oldest);
    }
    this.recentRaw.set(id, raw);
  }

  /** Downloads the image bytes for a message previously seen via `rememberRaw`. */
  async downloadMedia(id: string): Promise<Buffer> {
    const raw = this.recentRaw.get(id);
    if (!raw) throw new Error(`downloadMedia: unknown message id ${id}`);
    return downloadMediaMessage(raw as never, "buffer", {});
  }
```

Wire `rememberRaw` into the existing upsert loop. In `attachHandlers`, change:

```ts
for (const raw of payload.messages) {
  const message = normalizeMessage(raw);
  if (message) handlers.onMessage(message);
}
```

to:

```ts
for (const raw of payload.messages) {
  handlers.rememberRaw?.(raw);
  const message = normalizeMessage(raw);
  if (message) handlers.onMessage(message);
}
```

Add `rememberRaw` to the `Handlers` interface as optional (so existing test fakes that build a bare `Handlers` object do not need updating):

```ts
export interface Handlers {
  onMessage: (message: InboundMessage) => void;
  onReconnect: (shouldReconnect: boolean) => void;
  rememberRaw?: (raw: WAMessageLike) => void;
}
```

Wire it in `start()`, in the `attachHandlers(this.sock, { ... })` call:

```ts
    attachHandlers(this.sock, {
      onMessage: this.onMessage,
      rememberRaw: (raw) => this.rememberRaw(raw),
      onReconnect: (shouldReconnect) => {
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pnpm vitest run tests/session.test.ts -t downloadMedia`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `pnpm test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/transport/session.ts tests/session.test.ts
git commit -m "feat: cache raw inbound messages briefly so images can be downloaded on demand"
```

---

### Task 3: `snapshot` route

**Files:**

- Modify: `src/transport/router.ts`
- Test: `tests/router.test.ts`

**Interfaces:**

- Consumes: `InboundMessage.media` (Task 1).
- Produces: `Route` gains `{ kind: "snapshot"; userId: number; media: MediaPayload }`; `IgnoreReason` gains `"media-unsupported-here"`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/router.test.ts`, as a new top-level `describe` block after `describe("mention gating", ...)`:

```ts
describe("snapshot routing", () => {
  function imgMsg(chatJid: string, senderE164: string): InboundMessage {
    return {
      id: "img1",
      key: { id: "img1", remoteJid: chatJid },
      chatJid,
      senderJid: `${senderE164.slice(1)}@s.whatsapp.net`,
      senderE164,
      text: "",
      media: { mimetype: "image/jpeg", caption: null },
      timestamp: new Date("2026-07-27T12:00:00Z"),
    };
  }

  it("routes a DM image from the DM's own user to snapshot", () => {
    const m = imgMsg("15555550101@s.whatsapp.net", "+15555550101");
    expect(routeMessage(m, cfg)).toEqual({
      kind: "snapshot",
      userId: 2,
      media: { mimetype: "image/jpeg", caption: null },
    });
  });

  it("ignores a group image rather than routing it as a text capture", () => {
    // A group image falling through to `group` would extract from a caption
    // (if any) as if it were transcript text, silently discarding the image.
    const m = imgMsg("123@g.us", "+15555550100");
    expect(routeMessage(m, cfg)).toEqual({
      kind: "ignore",
      reason: "media-unsupported-here",
    });
  });

  it("ignores a DM image sent into the other user's DM chat", () => {
    const m = imgMsg("15555550101@s.whatsapp.net", "+15555550100");
    expect(routeMessage(m, cfg)).toEqual({
      kind: "ignore",
      reason: "media-unsupported-here",
    });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm vitest run tests/router.test.ts -t "snapshot routing"`
Expected: FAIL — `media-unsupported-here` and `snapshot` are not produced; images currently fall through to `dm`/`group`/`ignore` with the wrong reason.

- [ ] **Step 3: Implement in `router.ts`**

Add `MediaPayload` to the import:

```ts
import type { ChannelKind, InboundMessage, MediaPayload } from "../types.js";
```

Extend `Route` and `IgnoreReason`:

```ts
export type Route =
  | { kind: "group"; userId: number }
  | { kind: "dm"; userId: number }
  | { kind: "question"; userId: number; text: string; channel: ChannelKind }
  // A DM image from the DM's own user. Media never reaches `question` or the
  // capture buffer — it is routed here before either.
  | { kind: "snapshot"; userId: number; media: MediaPayload }
  | { kind: "ignore"; reason: IgnoreReason };

export type IgnoreReason =
  | "unresolved-sender"
  | "unknown-sender"
  | "chat-not-allowlisted"
  // A group image, or a DM image from anyone but that DM's own user. Distinct
  // from "chat-not-allowlisted": the chat itself may be perfectly allowlisted,
  // it is the media that has nowhere to go here.
  | "media-unsupported-here";
```

In `routeMessage`, right after `const isOwnDm = ...` (before the `question` branch), add:

```ts
if (msg.media) {
  if (sender && isOwnDm) {
    return { kind: "snapshot", userId: sender.userId, media: msg.media };
  }
  return { kind: "ignore", reason: "media-unsupported-here" };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm vitest run tests/router.test.ts -t "snapshot routing"`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `pnpm test`
Expected: PASS — every existing `routeMessage` case is text-only (`media` undefined), so the new branch never fires for them.

- [ ] **Step 6: Commit**

```bash
git add src/transport/router.ts tests/router.test.ts
git commit -m "feat: route a DM image to snapshot; ignore media anywhere else"
```

---

### Task 4: OCR module

**Files:**

- Create: `src/ocr/vision.swift`
- Create: `src/ocr/vision.ts`
- Create: `src/ocr/tesseract.ts`
- Create: `src/ocr/index.ts`
- Test: `tests/ocr.test.ts`

**Interfaces:**

- Produces: `extractText(bytes: Buffer, runner?: OcrRunner): Promise<{ text: string; engine: "vision" | "tesseract" }>`.

Both engines are CLI tools invoked by path, so the module is testable without a real macOS host or a real tesseract binary: `runVision`/`runTesseract` are injected as an `OcrRunner`, matching the `fetchImpl` injection pattern already used in `extract/extractor.ts`. A real-image smoke test is a manual step (Task 8), not part of `pnpm test` — CI may not run on macOS.

- [ ] **Step 1: Write the failing tests**

Create `tests/ocr.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import { extractText, type OcrRunner } from "../src/ocr/index.js";

function runner(over: Partial<OcrRunner> = {}): OcrRunner {
  return {
    platform: "darwin",
    runVision: vi.fn(async () => "Priya Raghavan\nDirector of Ops, Halvorsen"),
    runTesseract: vi.fn(async () => "Priya Raghavan"),
    ...over,
  };
}

describe("extractText", () => {
  it("uses Vision on macOS and reports the engine", async () => {
    const r = runner();
    const out = await extractText(Buffer.from("fake-jpeg"), r);
    expect(out.engine).toBe("vision");
    expect(out.text).toContain("Priya Raghavan");
    expect(r.runTesseract).not.toHaveBeenCalled();
  });

  it("falls back to tesseract when Vision throws", async () => {
    const r = runner({
      runVision: vi.fn(async () => {
        throw new Error("vision shim failed");
      }),
    });
    const out = await extractText(Buffer.from("fake-jpeg"), r);
    expect(out.engine).toBe("tesseract");
    expect(out.text).toBe("Priya Raghavan");
  });

  it("goes straight to tesseract on a non-macOS platform", async () => {
    const r = runner({ platform: "linux" });
    const out = await extractText(Buffer.from("fake-jpeg"), r);
    expect(out.engine).toBe("tesseract");
    expect(r.runVision).not.toHaveBeenCalled();
  });

  it("returns empty text rather than throwing when both engines find nothing", async () => {
    const r = runner({
      runVision: vi.fn(async () => ""),
    });
    const out = await extractText(Buffer.from("fake-jpeg"), r);
    expect(out.text).toBe("");
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm vitest run tests/ocr.test.ts`
Expected: FAIL — `src/ocr/index.ts` does not exist.

- [ ] **Step 3: Write `vision.swift`**

Create `src/ocr/vision.swift`:

```swift
#!/usr/bin/swift
import Vision
import AppKit

guard CommandLine.arguments.count > 1,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write("usage: vision.swift <image-path>\n".data(using: .utf8)!)
    exit(1)
}

let request = VNRecognizeTextRequest { request, error in
    guard error == nil,
          let observations = request.results as? [VNRecognizedTextObservation]
    else { exit(1) }
    for observation in observations {
        if let candidate = observation.topCandidates(1).first {
            print(candidate.string)
        }
    }
    exit(0)
}
request.recognitionLevel = .accurate

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try? handler.perform([request])
```

- [ ] **Step 4: Write `vision.ts`**

Create `src/ocr/vision.ts`:

```ts
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const execFileAsync = promisify(execFile);
const SCRIPT_PATH = join(
  dirname(fileURLToPath(import.meta.url)),
  "vision.swift",
);

export async function runVision(imagePath: string): Promise<string> {
  const { stdout } = await execFileAsync("swift", [SCRIPT_PATH, imagePath], {
    timeout: 30_000,
  });
  return stdout;
}
```

- [ ] **Step 5: Write `tesseract.ts`**

Create `src/ocr/tesseract.ts`:

```ts
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function runTesseract(imagePath: string): Promise<string> {
  // "stdout" as the output base tells tesseract to print to stdout instead
  // of writing a .txt file next to the input.
  const { stdout } = await execFileAsync("tesseract", [imagePath, "stdout"], {
    timeout: 30_000,
  });
  return stdout;
}
```

- [ ] **Step 6: Write `index.ts`**

Create `src/ocr/index.ts`:

```ts
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runVision } from "./vision.js";
import { runTesseract } from "./tesseract.js";

export interface OcrResult {
  text: string;
  engine: "vision" | "tesseract";
}

export interface OcrRunner {
  platform: NodeJS.Platform;
  runVision(imagePath: string): Promise<string>;
  runTesseract(imagePath: string): Promise<string>;
}

const defaultRunner: OcrRunner = {
  platform: process.platform,
  runVision,
  runTesseract,
};

/**
 * Vision on macOS, tesseract everywhere else or when Vision fails. Neither
 * engine takes bytes directly, so this writes a temp file for the duration of
 * the call and always cleans it up.
 */
export async function extractText(
  bytes: Buffer,
  runner: OcrRunner = defaultRunner,
): Promise<OcrResult> {
  const dir = await mkdtemp(join(tmpdir(), "prmm-ocr-"));
  const imagePath = join(dir, "snapshot");
  try {
    await writeFile(imagePath, bytes);

    if (runner.platform === "darwin") {
      try {
        const text = await runner.runVision(imagePath);
        return { text: text.trim(), engine: "vision" };
      } catch (error) {
        console.warn("vision OCR failed, falling back to tesseract", error);
      }
    }

    const text = await runner.runTesseract(imagePath);
    return { text: text.trim(), engine: "tesseract" };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `pnpm vitest run tests/ocr.test.ts`
Expected: PASS, all four cases.

- [ ] **Step 8: Run the full suite**

Run: `pnpm test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add src/ocr tests/ocr.test.ts
git commit -m "feat: OCR module — macOS Vision primary, tesseract fallback"
```

---

### Task 5: Snapshot extraction prompt, shared retry path

**Files:**

- Create: `src/extract/snapshot-prompt.ts`
- Modify: `src/extract/extractor.ts`
- Test: `tests/prompt.test.ts` (new `describe` block for the snapshot prompt)
- Test: `tests/extractor.test.ts` (new cases for `extractFromText`)

**Interfaces:**

- Consumes: `ExtractionResultSchema` (unchanged, from `extract/schema.ts`).
- Produces: `buildSnapshotPrompt(ocrText: string, caption: string | null): string`; `SNAPSHOT_SYSTEM_PROMPT: string`; `ChatExtractor.extractFromText(ocrText: string, caption: string | null): Promise<ExtractionResult>` on both `OllamaExtractor` and `OpenAiCompatExtractor`.

The transcript prompt (`prompt.ts`) cannot be reused: it opens with a `Speakers:` roster and instructs the model to attribute statements to whoever sent them, which is meaningless for a profile screenshot and risks inventing a conversation around it. This task adds a second prompt and threads it through the _same_ retry/parse/validate loop `ChatExtractor` already has, rather than duplicating that loop.

- [ ] **Step 1: Write the failing tests**

Add to `tests/prompt.test.ts`, as a new top-level `describe` block:

```ts
import {
  SNAPSHOT_SYSTEM_PROMPT,
  buildSnapshotPrompt,
} from "../src/extract/snapshot-prompt.js";

describe("buildSnapshotPrompt", () => {
  it("includes the OCR'd text and the caption when present", () => {
    const prompt = buildSnapshotPrompt(
      "Priya Raghavan\nDirector of Ops, Halvorsen",
      "this is User B's new boss",
    );
    expect(prompt).toContain("Priya Raghavan");
    expect(prompt).toContain("this is User B's new boss");
  });

  it("omits the caption line when there is none", () => {
    const prompt = buildSnapshotPrompt("Priya Raghavan", null);
    expect(prompt).not.toMatch(/caption/i);
  });
});

describe("SNAPSHOT_SYSTEM_PROMPT", () => {
  it("says the text describes a person, not a conversation", () => {
    expect(SNAPSHOT_SYSTEM_PROMPT).toMatch(/not a conversation/i);
  });

  it("warns against treating the sender as the subject", () => {
    expect(SNAPSHOT_SYSTEM_PROMPT).toMatch(
      /sender.*not.*subject|not.*treat.*sender/i,
    );
  });
});
```

Add to `tests/extractor.test.ts`, inside `describe("OllamaExtractor", ...)`:

```ts
it("extractFromText uses the snapshot prompt, not the transcript one", async () => {
  const fetchImpl = fakeFetch({
    people: [
      {
        name: "Priya Raghavan",
        company: "Halvorsen",
        context: "Director of Ops",
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
    ROSTER,
    fetchImpl as unknown as typeof fetch,
  );
  const out = await ex.extractFromText(
    "Priya Raghavan\nDirector of Ops, Halvorsen",
    null,
  );
  expect(out.people[0]?.name).toBe("Priya Raghavan");

  const body = JSON.parse(fetchImpl.mock.calls[0]?.[1]?.body as string);
  expect(body.messages[0].content).toMatch(/not a conversation/i);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm vitest run tests/prompt.test.ts tests/extractor.test.ts`
Expected: FAIL — `snapshot-prompt.ts` does not exist; `extractFromText` is not a method.

- [ ] **Step 3: Write `snapshot-prompt.ts`**

Create `src/extract/snapshot-prompt.ts`:

```ts
export const SNAPSHOT_SYSTEM_PROMPT = `You extract a relationship fact from text read by OCR off an image the user sent.
This text describes a person, not a conversation between people — do not
invent speakers or attribute anything to a sender. Do not treat the sender as
the subject unless the image is clearly a selfie or self-introduction.

Return ONLY JSON matching this shape:
{"people":[{"name":"","aliases":[],"company":null,"context":"","confidence":0.0}],
 "memories":[{"about":"","content":"","category":"relationship","confidence":0.0}],
 "commitments":[],
 "dates":[]}

Rules:
- "commitments" and "dates" are always empty arrays here — a profile has none.
- Fold a title or headline (e.g. "Director of Ops") into the person's "context".
- If the text states something narrative about the person (years of
  experience, a prior employer, what they are known for), also record a
  "memories" entry with "about" exactly matching the person's "name".
- confidence is 0.0-1.0. OCR text is noisier than a typed message — use below
  0.5 for a name or title you are not confident the OCR read correctly.
- Omit anything you did not read in the text. Never invent a detail.
- If the text is too garbled to identify a person at all, return empty arrays.`;

export function buildSnapshotPrompt(
  ocrText: string,
  caption: string | null,
): string {
  const captionLine = caption
    ? `\n\nUser's caption on the image: ${caption}`
    : "";
  return `Text read from the image:\n${ocrText}${captionLine}`;
}
```

- [ ] **Step 4: Refactor `extractor.ts` to share the retry loop**

In `src/extract/extractor.ts`, replace the `ChatExtractor` class body:

```ts
abstract class ChatExtractor implements Extractor {
  protected abstract complete(prompt: string): Promise<string>;
  /** The participant roster shown to the model, so it can attribute by name. */
  protected abstract roster(): RosterEntry[];

  async extract(batch: CaptureBatch): Promise<ExtractionResult> {
    const prompt = buildPrompt(batch, this.roster());

    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const raw = await this.complete(prompt);
        return ExtractionResultSchema.parse(JSON.parse(raw));
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

with:

```ts
abstract class ChatExtractor implements Extractor {
  /** `systemPrompt` lets the snapshot path use a different system message on the same transport. */
  protected abstract complete(
    systemPrompt: string,
    userPrompt: string,
  ): Promise<string>;
  /** The participant roster shown to the model, so it can attribute by name. */
  protected abstract roster(): RosterEntry[];

  private async runPrompt(
    systemPrompt: string,
    userPrompt: string,
  ): Promise<ExtractionResult> {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const raw = await this.complete(systemPrompt, userPrompt);
        return ExtractionResultSchema.parse(JSON.parse(raw));
      } catch (error) {
        if (attempt === 1) {
          throw new Error(`extraction failed after retry: ${String(error)}`);
        }
      }
    }

    throw new Error("extraction failed: unreachable");
  }

  async extract(batch: CaptureBatch): Promise<ExtractionResult> {
    return this.runPrompt(SYSTEM_PROMPT, buildPrompt(batch, this.roster()));
  }

  /** OCR'd text from a snapshot capture, not a transcript batch. */
  async extractFromText(
    ocrText: string,
    caption: string | null,
  ): Promise<ExtractionResult> {
    return this.runPrompt(
      SNAPSHOT_SYSTEM_PROMPT,
      buildSnapshotPrompt(ocrText, caption),
    );
  }
}
```

Add the import at the top:

```ts
import {
  buildSnapshotPrompt,
  SNAPSHOT_SYSTEM_PROMPT,
} from "./snapshot-prompt.js";
```

Update both `complete()` implementations to accept and use `systemPrompt`. In `OllamaExtractor`:

```ts
  protected async complete(
    systemPrompt: string,
    userPrompt: string,
  ): Promise<string> {
    const res = await this.fetchImpl(`${this.baseUrl}/api/chat`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      signal: AbortSignal.timeout(EXTRACTION_TIMEOUT_MS),
      body: JSON.stringify({
        model: this.model,
        stream: false,
        format: "json",
        options: { temperature: 0 },
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
      }),
    });

    if (!res.ok) throw new Error(`ollama responded ${res.status}`);
    const body = (await res.json()) as { message?: { content?: string } };
    return body.message?.content ?? "";
  }
```

In `OpenAiCompatExtractor`:

```ts
  protected async complete(
    systemPrompt: string,
    userPrompt: string,
  ): Promise<string> {
    const res = await this.fetchImpl(`${this.baseUrl}/v1/chat/completions`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${this.apiKey}`,
      },
      signal: AbortSignal.timeout(EXTRACTION_TIMEOUT_MS),
      body: JSON.stringify({
        model: this.model,
        temperature: 0,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
      }),
    });

    if (!res.ok) throw new Error(`model endpoint responded ${res.status}`);
    const body = (await res.json()) as {
      choices?: { message?: { content?: string } }[];
    };
    return body.choices?.[0]?.message?.content ?? "";
  }
```

Also update the `Extractor` interface to declare the new method so both concrete classes are checked against it:

```ts
export interface Extractor {
  extract(batch: CaptureBatch): Promise<ExtractionResult>;
  extractFromText(
    ocrText: string,
    caption: string | null,
  ): Promise<ExtractionResult>;
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm vitest run tests/prompt.test.ts tests/extractor.test.ts`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `pnpm test`
Expected: PASS. `tests/pipeline.test.ts`'s `extractorOf()` fake only implements `extract`, not `extractFromText` — check whether this now fails a structural-typing check. It does not: `extractorOf()`'s return value is inferred, not asserted against `Extractor`, so TypeScript does not require the extra method unless it is passed somewhere typed as `Extractor`. If `pnpm typecheck` reports a mismatch at the `deps({ extractor })` call site in `tests/pipeline.test.ts`, add a no-op `extractFromText: vi.fn(async () => ({ people: [], memories: [], commitments: [], dates: [] }))` to `extractorOf()`'s returned object to satisfy the interface.

- [ ] **Step 7: Commit**

```bash
git add src/extract/snapshot-prompt.ts src/extract/extractor.ts tests/prompt.test.ts tests/extractor.test.ts
git commit -m "feat: snapshot extraction prompt, sharing the retry loop with the transcript path"
```

---

### Task 6: Extract `storeExtraction` from `pipeline.ts`

**Files:**

- Modify: `src/pipeline.ts`
- Test: `tests/pipeline.test.ts` (no new cases required — this task's contract is that the existing suite stays green)

**Interfaces:**

- Produces: `storeExtraction(extraction: ExtractionResult, ctx: StoreContext, deps: StoreDeps): Promise<CaptureOutcome>`, exported for Task 7 to call from the snapshot path.

This is a pure refactor: the body of `runCapture` from `let known: KnownPerson[]` through the final `return` is lifted into a new function, and `runCapture` becomes a thin wrapper that computes `userId`/`visibility`/`batchId` from a `CaptureBatch` and calls it. One real bug is fixed in the same pass: `aboutTheOther` currently keys off `isDm`, but the actual thing that matters is whether the memory is about to be stored `private` — today those are equivalent (DM always implies `private`, group always implies `shared`), but Task 7's snapshot path is DM-originated and forces `shared`, and the `isDm`-keyed check would wrongly refuse a _shared_, announced fact about the other participant using a gate meant for _private_ ones.

- [ ] **Step 1: Confirm the safety net**

Run: `pnpm vitest run tests/pipeline.test.ts`
Expected: PASS (current baseline — every test in this file must still pass after Steps 2-3, unchanged).

- [ ] **Step 2: Extract `storeExtraction`**

In `src/pipeline.ts`, add these two interfaces above `runCapture` (after `CONFIDENCE_FLOOR`):

```ts
/** Everything `storeExtraction` needs about the batch it is storing, independent of where it came from. */
export interface StoreContext {
  batchId: string;
  userId: number;
  visibility: Visibility;
  /** Free-form label recorded on `interactions.channel` — "group" | "dm" | "snapshot". */
  channel: string;
  occurredAt: Date;
  /** Truncated to 2000 chars before being passed in, matching the existing `interactions.raw_excerpt` cap. */
  rawExcerpt: string;
  participants: number[];
  /**
   * Resolves who said a given name, for routing an identity clarification to
   * the right DM. `runCapture` derives this from the batch transcript; a
   * snapshot capture has no transcript, so it always resolves to `userId`.
   */
  speakerFor: (name: string) => number;
}

export interface StoreDeps {
  repo: Repository;
  sharedOwnerUserId: number;
  participantUserIdFor: (personId: number) => number | undefined;
  allowPrivateAboutParticipant: boolean;
}
```

Replace the body of `runCapture` starting at `// Reads are never queued, ...` through the final `return { status, people: nameToId.size, memories: stored, questions, deferred, announcements };` — i.e. everything after `const deferred = { ... };` is removed from `runCapture` and becomes the new `storeExtraction`:

```ts
export async function storeExtraction(
  extraction: ExtractionResult,
  ctx: StoreContext,
  deps: StoreDeps,
): Promise<CaptureOutcome> {
  const {
    batchId,
    userId,
    visibility,
    channel,
    occurredAt,
    rawExcerpt,
    participants,
    speakerFor,
  } = ctx;
  const empty = {
    people: 0,
    memories: 0,
    questions: [] as string[],
    deferred: {
      commitments: extraction.commitments.length,
      dates: extraction.dates.length,
    },
    announcements: [] as string[],
  };

  let known: KnownPerson[];
  try {
    known = await deps.repo.findPeople(userId, visibility === "private");
  } catch {
    return { status: "parked", ...empty };
  }

  const deferred = empty.deferred;
  const nameToId = new Map<string, number>();
  const questions: string[] = [];
  const announcements: string[] = [];
  const pendingNames = new Set<string>();
  const candidateIds = new Map<string, number[]>();
  const askedBy = new Map<string, number>();
  let degraded = false;

  for (const candidate of extraction.people) {
    if (candidate.confidence < CONFIDENCE_FLOOR) {
      console.warn(
        `dropping low-confidence person "${candidate.name}" (${candidate.confidence})`,
      );
      continue;
    }

    const key = normalise(candidate.name);
    const opId = `${batchId}:person:${slug(key)}`;
    const logOpId = `${batchId}:reslog:${slug(key)}`;
    const decision = resolveIdentity(
      scoreCandidate(candidate, known),
      DEFAULT_BANDS,
    );

    if (decision.action === "match") {
      let personId = decision.personId;

      if (personId === null) {
        personId = await deps.repo.upsertPerson({
          userId,
          canonicalName: candidate.name,
          aliases: candidate.aliases,
          company: candidate.company,
          firstMetContext: candidate.context || null,
          visibility,
          personContactId: decision.personContactId,
          opId,
        });
        if (personId === null) return { status: "parked", ...empty };

        known = [
          ...known.filter(
            (person) => person.personContactId !== decision.personContactId,
          ),
          {
            id: personId,
            canonicalName: candidate.name,
            aliases: candidate.aliases,
            company: candidate.company,
            phone: null,
            email: null,
            personContactId: decision.personContactId,
          },
        ];
      }

      nameToId.set(key, personId);
      if (
        !(await deps.repo.logResolution({
          candidateName: candidate.name,
          chosenPersonId: personId,
          score: decision.score,
          action: "auto_match",
          opId: logOpId,
        }))
      ) {
        degraded = true;
      }
      continue;
    }

    if (decision.action === "ask") {
      questions.push(candidate.name);
      pendingNames.add(key);
      candidateIds.set(
        key,
        decision.candidates
          .map((c) => c.personId)
          .filter((id): id is number => id !== null),
      );
      askedBy.set(key, speakerFor(candidate.name));
      if (
        !(await deps.repo.logResolution({
          candidateName: candidate.name,
          chosenPersonId: null,
          score: decision.candidates[0]?.score ?? null,
          action: "asked",
          opId: logOpId,
        }))
      ) {
        degraded = true;
      }
      continue;
    }

    const id = await deps.repo.upsertPerson({
      userId,
      canonicalName: candidate.name,
      aliases: candidate.aliases,
      company: candidate.company,
      firstMetContext: candidate.context || null,
      visibility,
      personContactId: null,
      opId,
    });

    if (id === null) return { status: "parked", ...empty };

    nameToId.set(key, id);
    known = [
      ...known,
      {
        id,
        canonicalName: candidate.name,
        aliases: candidate.aliases,
        company: candidate.company,
        phone: null,
        email: null,
        personContactId: null,
      },
    ];
    if (
      !(await deps.repo.logResolution({
        candidateName: candidate.name,
        chosenPersonId: id,
        score: null,
        action: "created",
        opId: logOpId,
      }))
    ) {
      degraded = true;
    }
  }

  let stored = 0;
  let refused = false;
  const held = new Map<
    string,
    { content: string; category: string; confidence: number }[]
  >();

  for (const memory of extraction.memories) {
    if (memory.confidence < CONFIDENCE_FLOOR) {
      console.warn(`dropping low-confidence memory about "${memory.about}"`);
      continue;
    }

    const key = normalise(memory.about);
    const personId = nameToId.get(key);

    if (personId === undefined) {
      const bucket = held.get(key) ?? [];
      bucket.push({
        content: memory.content,
        category: memory.category,
        confidence: memory.confidence,
      });
      held.set(key, bucket);
      continue;
    }

    const aboutParticipant = deps.participantUserIdFor(personId);
    // Keyed on `visibility`, not on the originating channel: a snapshot
    // capture is DM-originated but forces `shared`, and the refusal below
    // exists only to stop a PRIVATE fact about the other participant from
    // landing invisibly — a shared, announced fact about them is not that.
    const aboutTheOther =
      visibility === "private" &&
      aboutParticipant !== undefined &&
      aboutParticipant !== userId;

    if (aboutTheOther && !deps.allowPrivateAboutParticipant) {
      announcements.push(
        `I won't record private notes about ${memory.about}. Say it in the group if you want it kept.`,
      );
      refused = true;
      continue;
    }

    const thoughtId = await deps.repo.captureMemory({
      content: memory.content,
      userId,
      personId,
      category: memory.category,
      confidence: memory.confidence,
      visibility,
      opId: `${batchId}:memory:${slug(key + memory.content)}`,
    });
    if (thoughtId === null) degraded = true;

    const interactionId = await deps.repo.recordInteraction({
      personId,
      occurredAt,
      channel,
      summary: memory.content,
      rawExcerpt,
      capturedBy: userId,
      participants,
      thoughtId,
      status: "extracted",
      opId: `${batchId}:interaction:${slug(key + memory.content)}`,
    });
    if (interactionId === null) degraded = true;

    if (aboutTheOther) {
      announcements.push(
        `Noted privately about ${memory.about}. ${memory.about} won't see this.`,
      );
    }

    stored += 1;
  }

  for (const key of held.keys()) {
    if (!pendingNames.has(key)) {
      questions.push(key);
      pendingNames.add(key);
    }
  }

  for (const name of questions) {
    const key = normalise(name);
    const clarificationId = await deps.repo.recordClarification({
      askedUserId: askedBy.get(key) ?? userId,
      kind: "identity",
      question: `Which "${name}" do you mean?`,
      context: {
        candidateName: name,
        candidatePersonIds: candidateIds.get(key) ?? [],
        heldMemories: held.get(key) ?? [],
        visibility,
      },
      opId: `${batchId}:clarify:${slug(key)}`,
    });
    if (clarificationId === null) degraded = true;
  }

  const status = degraded
    ? "degraded"
    : stored === 0 && refused
      ? "refused"
      : "stored";

  return {
    status,
    people: nameToId.size,
    memories: stored,
    questions,
    deferred,
    announcements,
  };
}
```

Now `runCapture` becomes:

```ts
export async function runCapture(
  batch: CaptureBatch,
  deps: CaptureDeps,
): Promise<CaptureOutcome> {
  const joined = batch.messages.map((m) => m.text).join("\n");
  const empty = {
    people: 0,
    memories: 0,
    questions: [] as string[],
    deferred: { commitments: 0, dates: 0 },
    announcements: [] as string[],
  };

  if (!looksRelevant(joined)) return { status: "skipped", ...empty };

  const batchId = batch.messages[0]?.id ?? "unknown";
  const attempt = deps.attempt ?? 0;
  const park = async (): Promise<CaptureOutcome> => {
    await deps.parkQueue.enqueue({
      kind: "retryExtraction",
      payload: batch,
      opId: `park:${batchId}`,
      attempts: attempt + 1,
    });
    return { status: "parked", ...empty };
  };

  let extraction: ExtractionResult;
  try {
    extraction = await deps.extractor.extract(batch);
  } catch {
    return park();
  }

  const isDm = batch.route.kind === "dm";
  const userId = isDm ? batch.route.userId : deps.sharedOwnerUserId;
  const visibility: Visibility = isDm ? "private" : "shared";

  const speakerFor = (name: string): number => {
    const needle = name.toLowerCase();
    const hit = batch.messages.find((m) =>
      m.text.toLowerCase().includes(needle),
    );
    const e164 = hit?.senderE164;
    return (e164 ? deps.userIdForE164(e164) : undefined) ?? userId;
  };

  const outcome = await storeExtraction(
    extraction,
    {
      batchId,
      userId,
      visibility,
      channel: batch.route.kind,
      occurredAt: batch.closedAt,
      rawExcerpt: joined.slice(0, 2000),
      participants: batch.participants,
      speakerFor,
    },
    {
      repo: deps.repo,
      sharedOwnerUserId: deps.sharedOwnerUserId,
      participantUserIdFor: deps.participantUserIdFor,
      allowPrivateAboutParticipant: deps.allowPrivateAboutParticipant,
    },
  );

  // storeExtraction's own "reads unreachable" park case returns a bare
  // `parked` outcome; a transcript batch's park must additionally re-queue
  // the batch itself for retry, which storeExtraction has no access to.
  if (outcome.status === "parked") return park();

  return outcome;
}
```

- [ ] **Step 3: Run the existing suite to confirm no behavior change**

Run: `pnpm test`
Expected: PASS — every case in `tests/pipeline.test.ts` unchanged and green. If anything fails, the refactor introduced a behavior difference; stop and diff against the original body rather than adjusting the test.

- [ ] **Step 4: Add one regression test for the visibility-based fix**

Add this import at the top of `tests/pipeline.test.ts`, alongside the existing `runCapture` import:

```ts
import { storeExtraction, type StoreDeps } from "../src/pipeline.js";
```

Add to `tests/pipeline.test.ts`, inside `describe("runCapture", ...)`:

```ts
it("does not refuse a SHARED memory about the other participant, unlike a private one", async () => {
  const r = repo();
  const storeDeps: StoreDeps = {
    repo: r,
    sharedOwnerUserId: 1,
    participantUserIdFor: () => 2, // person id below "belongs" to user 2
    allowPrivateAboutParticipant: false,
  };
  const extraction = {
    people: [person("User B")],
    memories: [memory("User B", "reads voraciously")],
    commitments: [] as never[],
    dates: [] as never[],
  };

  const out = await storeExtraction(
    extraction,
    {
      batchId: "b1",
      userId: 1,
      visibility: "shared",
      channel: "snapshot",
      occurredAt: new Date("2026-07-27T12:00:00Z"),
      rawExcerpt: "reads voraciously",
      participants: [1],
      speakerFor: () => 1,
    },
    storeDeps,
  );

  expect(out.status).toBe("stored");
  expect(out.memories).toBe(1);
  expect(r.captureMemory).toHaveBeenCalled();
});
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `pnpm vitest run tests/pipeline.test.ts`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `pnpm test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/pipeline.ts tests/pipeline.test.ts
git commit -m "refactor: extract storeExtraction from runCapture; key aboutTheOther on visibility, not channel"
```

---

### Task 7: `snapshot/state.ts` and `snapshot/capture.ts`

**Files:**

- Create: `src/snapshot/state.ts`
- Create: `src/snapshot/capture.ts`
- Test: `tests/snapshot-state.test.ts`
- Test: `tests/snapshot-capture.test.ts`

**Interfaces:**

- Consumes: `extractText` (Task 4), `Extractor.extractFromText` (Task 5), `storeExtraction`/`StoreDeps` (Task 6).
- Produces: `PrivateReplyWindow` class with `record(chatJid, ids)` / `consumePrivateReply(chatJid)`; `runSnapshotCapture(input, deps): Promise<CaptureOutcome & { ackText: string | null }>`.

- [ ] **Step 1: Write the failing tests for `state.ts`**

Create `tests/snapshot-state.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { PrivateReplyWindow } from "../src/snapshot/state.js";

describe("PrivateReplyWindow", () => {
  it("returns the recorded ids on the first consume after a record", () => {
    const w = new PrivateReplyWindow();
    w.record("dm1", { personIds: [10], memoryIds: [20] });
    expect(w.consumePrivateReply("dm1")).toEqual({
      personIds: [10],
      memoryIds: [20],
    });
  });

  it("returns null for a chat with no preceding capture", () => {
    const w = new PrivateReplyWindow();
    expect(w.consumePrivateReply("dm1")).toBeNull();
  });

  it("clears the slot once consumed — a second reply of 'private' does nothing", () => {
    const w = new PrivateReplyWindow();
    w.record("dm1", { personIds: [10], memoryIds: [] });
    w.consumePrivateReply("dm1");
    expect(w.consumePrivateReply("dm1")).toBeNull();
  });

  it("any other message in the same chat clears the slot without consuming it", () => {
    const w = new PrivateReplyWindow();
    w.record("dm1", { personIds: [10], memoryIds: [] });
    w.clear("dm1");
    expect(w.consumePrivateReply("dm1")).toBeNull();
  });

  it("keeps chats independent", () => {
    const w = new PrivateReplyWindow();
    w.record("dm1", { personIds: [10], memoryIds: [] });
    expect(w.consumePrivateReply("dm2")).toBeNull();
    expect(w.consumePrivateReply("dm1")).toEqual({
      personIds: [10],
      memoryIds: [],
    });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm vitest run tests/snapshot-state.test.ts`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement `state.ts`**

Create `src/snapshot/state.ts`:

```ts
export interface CapturedIds {
  personIds: number[];
  memoryIds: number[];
}

/**
 * In-memory, single-slot, per-DM "did a snapshot capture just happen here"
 * window. Deliberately not durable: a `private` reply corrects the capture
 * that produced it, nothing older, and a restart or any other intervening
 * message closes the window. See the design's Visibility section for why
 * this is not `clarifications`.
 */
export class PrivateReplyWindow {
  private readonly slots = new Map<string, CapturedIds>();

  record(chatJid: string, ids: CapturedIds): void {
    this.slots.set(chatJid, ids);
  }

  /** Any message other than the immediate `private` reply closes the window. */
  clear(chatJid: string): void {
    this.slots.delete(chatJid);
  }

  /** Consuming returns the ids once, then closes the window — a second `private` does nothing. */
  consumePrivateReply(chatJid: string): CapturedIds | null {
    const ids = this.slots.get(chatJid);
    if (!ids) return null;
    this.slots.delete(chatJid);
    return ids;
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pnpm vitest run tests/snapshot-state.test.ts`
Expected: PASS.

- [ ] **Step 5: Write the failing tests for `capture.ts`**

Create `tests/snapshot-capture.test.ts`, following the mock-repo pattern already established in `tests/pipeline.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import {
  runSnapshotCapture,
  type SnapshotCaptureDeps,
} from "../src/snapshot/capture.js";
import type { Repository } from "../src/store/repository.js";

function repo(overrides: Partial<Repository> = {}): Repository {
  return {
    findPeople: vi.fn(async () => []),
    upsertPerson: vi.fn(async () => 10),
    captureMemory: vi.fn(async () => 20),
    recordInteraction: vi.fn(async () => 30),
    logResolution: vi.fn(async () => true),
    recordClarification: vi.fn(async () => 40),
    whereMet: vi.fn(async () => null),
    lastSpoke: vi.fn(async () => null),
    memoriesAbout: vi.fn(async () => []),
    peopleAt: vi.fn(async () => []),
    ...overrides,
  };
}

function deps(over: Partial<SnapshotCaptureDeps> = {}): SnapshotCaptureDeps {
  return {
    repo: repo(),
    ocr: {
      extractText: vi.fn(async () => ({
        text: "Priya Raghavan\nDirector of Ops, Halvorsen",
        engine: "vision" as const,
      })),
    },
    extractor: {
      extractFromText: vi.fn(async () => ({
        people: [
          {
            name: "Priya Raghavan",
            aliases: [],
            company: "Halvorsen",
            context: "Director of Ops",
            confidence: 0.9,
          },
        ],
        memories: [],
        commitments: [],
        dates: [],
      })),
    },
    sharedOwnerUserId: 1,
    participantUserIdFor: () => undefined,
    otherUserName: "User B",
    ...over,
  };
}

const input = {
  userId: 1,
  dmJid: "15555550100@s.whatsapp.net",
  bytes: Buffer.from("fake-jpeg"),
  caption: null,
  occurredAt: new Date("2026-07-27T12:00:00Z"),
};

describe("runSnapshotCapture", () => {
  it("stores a person as SHARED and composes the acknowledgement", async () => {
    const r = repo();
    const out = await runSnapshotCapture(input, deps({ repo: r }));

    expect(out.status).toBe("stored");
    expect(r.upsertPerson).toHaveBeenCalledWith(
      expect.objectContaining({
        visibility: "shared",
        canonicalName: "Priya Raghavan",
      }),
    );
    expect(out.ackText).toMatch(/Priya Raghavan/);
    expect(out.ackText).toMatch(/shared/i);
    expect(out.ackText).toMatch(/User B/);
  });

  it("returns parked when OCR finds no text", async () => {
    const out = await runSnapshotCapture(
      input,
      deps({
        ocr: {
          extractText: vi.fn(async () => ({
            text: "",
            engine: "vision" as const,
          })),
        },
      }),
    );
    expect(out.status).toBe("parked");
    expect(out.ackText).toBeNull();
  });

  it("returns refused when extraction finds no usable candidate", async () => {
    const out = await runSnapshotCapture(
      input,
      deps({
        extractor: {
          extractFromText: vi.fn(async () => ({
            people: [],
            memories: [],
            commitments: [],
            dates: [],
          })),
        },
      }),
    );
    expect(out.status).toBe("refused");
    expect(out.ackText).toBeNull();
  });

  it("hands back the ids of what it stored, for the private-reply window", async () => {
    const out = await runSnapshotCapture(input, deps());
    expect(out.storedIds.personIds).toEqual([10]);
  });
});
```

- [ ] **Step 6: Run the tests to verify they fail**

Run: `pnpm vitest run tests/snapshot-capture.test.ts`
Expected: FAIL — module does not exist.

`storeExtraction` (Task 6) does not yet return the ids it wrote, only counts — and `runSnapshotCapture` needs the real person id to hand to the `private`-reply window (Task 8). Thread that through `pipeline.ts` first, so `capture.ts` is written once, correctly, with no placeholder to come back and fix.

- [ ] **Step 7: Thread real ids out of `storeExtraction`**

In `src/pipeline.ts`, add a field to `CaptureOutcome`:

```ts
export interface CaptureOutcome {
  status: "skipped" | "stored" | "degraded" | "parked" | "refused";
  people: number;
  memories: number;
  questions: string[];
  deferred: { commitments: number; dates: number };
  announcements: string[];
  /** The person and memory ids actually written, for callers that need to act on them (e.g. a correction window). */
  storedIds: { personIds: number[]; memoryIds: number[] };
}
```

Add `storedIds: { personIds: [], memoryIds: [] }` to both places `empty` is declared as a plain object — `runCapture`'s `const empty = { ... }` and `storeExtraction`'s own `const empty = { ... }` — so each reads:

```ts
const empty = {
  people: 0,
  memories: 0,
  questions: [] as string[],
  deferred: { commitments: 0, dates: 0 },
  announcements: [] as string[],
  storedIds: { personIds: [] as number[], memoryIds: [] as number[] },
};
```

(`storeExtraction`'s `empty` additionally spreads `deferred` from the real `extraction.commitments`/`extraction.dates` lengths, per Task 6 Step 2 — keep that part unchanged, only add the `storedIds` line above it.)

In `storeExtraction`, add two trackers alongside `nameToId`/`questions`/`announcements`:

```ts
const personIds: number[] = [];
const memoryIds: number[] = [];
```

In the `match` branch, right after `nameToId.set(key, personId);`, add:

```ts
personIds.push(personId);
```

In the `create` branch (the final branch of the `for (const candidate of extraction.people)` loop), right after `nameToId.set(key, id);`, add:

```ts
personIds.push(id);
```

In the memories loop, right after `if (thoughtId === null) degraded = true;`, add:

```ts
if (thoughtId !== null) memoryIds.push(thoughtId);
```

Finally, add `storedIds: { personIds, memoryIds }` to `storeExtraction`'s closing return statement, so it reads:

```ts
return {
  status,
  people: nameToId.size,
  memories: stored,
  questions,
  deferred,
  announcements,
  storedIds: { personIds, memoryIds },
};
```

- [ ] **Step 8: Run the existing suite to confirm the shape change is safe**

Run: `pnpm test`
Expected: PASS. `storedIds` is additive on an interface; nothing that only reads `.status`/`.people`/`.memories` breaks. If `pnpm typecheck` flags a test file constructing a literal `CaptureOutcome` (via `toEqual` against the full object rather than `objectContaining`), add `storedIds: { personIds: [...], memoryIds: [...] }` matching what that test's mocked `repo()` actually resolves — `upsertPerson`/`captureMemory` in the shared fakes already return fixed ids (`10`, `20`), so the expected values are determined by the existing mocks, not new ones.

- [ ] **Step 9: Implement `capture.ts`**

Create `src/snapshot/capture.ts`:

```ts
import type { OcrResult } from "../ocr/index.js";
import {
  storeExtraction,
  type CaptureOutcome,
  type StoreDeps,
} from "../pipeline.js";
import type { Repository } from "../store/repository.js";

export interface SnapshotOcr {
  extractText(bytes: Buffer): Promise<OcrResult>;
}

export interface SnapshotExtractor {
  extractFromText(
    ocrText: string,
    caption: string | null,
  ): Promise<{
    people: {
      name: string;
      aliases: string[];
      company: string | null;
      context: string;
      confidence: number;
    }[];
    memories: {
      about: string;
      content: string;
      category: string;
      confidence: number;
    }[];
  }>;
}

export interface SnapshotCaptureDeps {
  repo: Repository;
  ocr: SnapshotOcr;
  extractor: SnapshotExtractor;
  sharedOwnerUserId: number;
  participantUserIdFor: (personId: number) => number | undefined;
  /** Named in the acknowledgement ("... User B can see this"); the other configured user's display name. */
  otherUserName: string;
}

export interface SnapshotCaptureInput {
  userId: number;
  dmJid: string;
  bytes: Buffer;
  caption: string | null;
  occurredAt: Date;
}

export interface SnapshotCaptureResult extends CaptureOutcome {
  /** Null when nothing was announced — a parked or refused capture. */
  ackText: string | null;
}

const empty = {
  people: 0,
  memories: 0,
  questions: [] as string[],
  deferred: { commitments: 0, dates: 0 },
  announcements: [] as string[],
  storedIds: { personIds: [] as number[], memoryIds: [] as number[] },
};

export async function runSnapshotCapture(
  input: SnapshotCaptureInput,
  deps: SnapshotCaptureDeps,
): Promise<SnapshotCaptureResult> {
  const ocr = await deps.ocr.extractText(input.bytes);
  if (!ocr.text) {
    return { status: "parked", ...empty, ackText: null };
  }

  const extraction = await deps.extractor.extractFromText(
    ocr.text,
    input.caption,
  );
  if (extraction.people.length === 0) {
    return { status: "refused", ...empty, ackText: null };
  }

  const batchId = `snapshot:${input.dmJid}:${input.occurredAt.getTime()}`;
  const storeDeps: StoreDeps = {
    repo: deps.repo,
    sharedOwnerUserId: deps.sharedOwnerUserId,
    participantUserIdFor: deps.participantUserIdFor,
    // A shared, announced capture is never the "private about the other
    // participant" case this flag guards — see storeExtraction's own note.
    allowPrivateAboutParticipant: true,
  };

  const outcome = await storeExtraction(
    { ...extraction, commitments: [], dates: [] },
    {
      batchId,
      userId: input.userId,
      visibility: "shared",
      channel: "snapshot",
      occurredAt: input.occurredAt,
      rawExcerpt: ocr.text.slice(0, 2000),
      participants: [input.userId],
      speakerFor: () => input.userId,
    },
    storeDeps,
  );

  if (outcome.status === "parked" || outcome.people === 0) {
    return { ...outcome, ackText: null };
  }

  const primary = extraction.people[0];
  const ackText = primary
    ? `Read a profile for **${primary.name}**${primary.context ? ` — ${primary.context}` : ""}. Saved as shared; ${deps.otherUserName} can see this. Reply \`private\` to restrict it.`
    : null;

  return { ...outcome, ackText };
}
```

- [ ] **Step 10: Run the tests to verify they pass**

Run: `pnpm vitest run tests/snapshot-capture.test.ts`
Expected: PASS.

- [ ] **Step 11: Run the full suite**

Run: `pnpm test`
Expected: PASS.

- [ ] **Step 12: Commit**

```bash
git add src/snapshot src/pipeline.ts tests/snapshot-state.test.ts tests/snapshot-capture.test.ts tests/pipeline.test.ts
git commit -m "feat: runSnapshotCapture and the private-reply window; thread stored ids out of storeExtraction"
```

---

### Task 8: Wire `index.ts`

**Files:**

- Modify: `src/index.ts`

No new test file — `index.ts` is the composition root and has none today (its pieces are unit-tested individually; this file is verified by the full suite plus the manual check below, matching the project's existing convention).

**Interfaces:**

- Consumes: `Route.snapshot` (Task 3), `WhatsAppSession.downloadMedia` (Task 2), `extractText` (Task 4), `Extractor.extractFromText` (Task 5), `runSnapshotCapture` (Task 7), `PrivateReplyWindow` (Task 7).

- [ ] **Step 1: Add the new imports**

In `src/index.ts`, add:

```ts
import { extractText } from "./ocr/index.js";
import { runSnapshotCapture } from "./snapshot/capture.js";
import { PrivateReplyWindow } from "./snapshot/state.js";
```

- [ ] **Step 2: Construct the private-reply window and a snapshot ack map**

Add near the other module-level construction, after `const buffer = new CaptureBuffer(...)` is declared further down is too late — add this right after `const participantRows = ...`/`answerDeps` block, before `const session = new WhatsAppSession(...)`:

```ts
const privateReplyWindow = new PrivateReplyWindow();
```

- [ ] **Step 3: Add `Repository.setVisibility`**

Flipping a captured person to `private` on a `private` reply is not a re-upsert (that would require re-supplying `canonicalName` and risk overwriting it) — it needs a dedicated method. Add it now, before wiring `index.ts`, so the wiring step below has something correct to call from the start.

In `src/store/repository.ts`, add to the `Repository` interface, after `recordClarification`:

```ts
  /**
   * Flips a person's (and their memories') visibility. The only current
   * caller is the snapshot `private` reply — see `snapshot/state.ts`.
   */
  setVisibility(
    personId: number,
    memoryIds: number[],
    visibility: Visibility,
    opId: string,
  ): Promise<boolean>;
```

In `src/store/pg-repository.ts`, add the implementation near `upsertPerson`:

```ts
  async setVisibility(
    personId: number,
    memoryIds: number[],
    visibility: Visibility,
    opId: string,
  ): Promise<boolean> {
    return this.once(opId, async () => {
      await this.sql.begin(async (tx) => {
        await tx`UPDATE prmm.people SET visibility = ${visibility}, updated_at = NOW() WHERE id = ${personId}`;
        if (memoryIds.length > 0) {
          await tx`UPDATE prmm.memories SET visibility = ${visibility}, updated_at = NOW() WHERE id = ANY(${memoryIds})`;
        }
      });
      return true;
    });
  }
```

In `src/store/queued-repository.ts`, add `"setVisibility"` to the `WriteKind` union, add the queued wrapper (mirroring `logResolution`'s shape — returns `boolean`, `false` when queued), and add the replay dispatch case:

```ts
  async setVisibility(
    personId: number,
    memoryIds: number[],
    visibility: Visibility,
    opId: string,
  ): Promise<boolean> {
    return (
      (await this.write(
        "setVisibility",
        { personId, memoryIds, visibility, opId },
        () => this.inner.setVisibility(personId, memoryIds, visibility, opId),
      )) !== null
    );
  }
```

In `dispatch`'s `switch`, add:

```ts
      case "setVisibility": {
        const p = op.payload as {
          personId: number;
          memoryIds: number[];
          visibility: Visibility;
          opId: string;
        };
        await this.inner.setVisibility(
          p.personId,
          p.memoryIds,
          p.visibility,
          p.opId,
        );
        return;
      }
```

Run: `pnpm test`
Expected: PASS. If a test file constructs a `Repository` fake object checked against the full interface (as `tests/pipeline.test.ts`'s `repo()` helper does), add `setVisibility: vi.fn(async () => true)` to it, matching the existing convention for every other repository method there.

- [ ] **Step 4: Handle the `snapshot` route and the `private` reply in `onMessage`**

Inside the `session`'s `onMessage` callback (the third constructor argument), after the existing `if (route.kind === "question") { ... return; }` block and before `buffer.add(message, route);`, add:

```ts
if (route.kind === "snapshot") {
  void track(
    session
      .downloadMedia(message.id)
      .then((bytes) =>
        runSnapshotCapture(
          {
            userId: route.userId,
            dmJid: message.chatJid,
            bytes,
            caption: route.media.caption,
            occurredAt: message.timestamp,
          },
          {
            repo,
            ocr: { extractText: (b) => extractText(b) },
            extractor,
            sharedOwnerUserId: cfg.sharedOwnerUserId,
            participantUserIdFor: (id) => participantUserId.get(id),
            otherUserName:
              cfg.users.find((u) => u.userId !== route.userId)?.displayName ??
              "the other user",
          },
        ),
      )
      .then(async (out) => {
        console.log("snapshot capture", out);
        if (out.ackText) {
          privateReplyWindow.record(message.chatJid, out.storedIds);
          await session
            .sendText(message.chatJid, out.ackText)
            .catch((e: unknown) => console.error("ack send failed", e));
        }
        const emoji =
          out.status === "stored" || out.status === "degraded"
            ? ACK[out.status]
            : null;
        if (emoji)
          await session
            .react(message.key, emoji)
            .catch((e: unknown) => console.error("ack failed", e));
      })
      .catch((error: unknown) =>
        console.error("snapshot capture failed", error),
      ),
  );
  return;
}

// A bare "private" reply corrects the snapshot capture that just landed in
// this DM — matched before anything else touches the buffer, and only when
// a capture is actually waiting to be corrected.
if (message.text.trim().toLowerCase() === "private") {
  const ids = privateReplyWindow.consumePrivateReply(message.chatJid);
  if (ids && ids.personIds[0] !== undefined) {
    void track(
      repo
        .setVisibility(
          ids.personIds[0],
          ids.memoryIds,
          "private",
          `private-reply:${message.id}`,
        )
        .then(() =>
          session.sendText(message.chatJid, "Got it — marked private."),
        )
        .catch((error: unknown) =>
          console.error("private reply failed", error),
        ),
    );
    return;
  }
  privateReplyWindow.clear(message.chatJid);
} else {
  privateReplyWindow.clear(message.chatJid);
}
```

- [ ] **Step 5: Add the `retrySnapshot` park-queue kind for a failed media download**

A media download failure (WhatsApp CDN transient error) must retry the same way a failed extraction does. Wrap the `session.downloadMedia` call from Step 3 in a catch that enqueues to `parkQueue`:

Replace the snapshot handling block's `.then((bytes) => ...)` chain start with:

```ts
      if (route.kind === "snapshot") {
        const snapshotPayload = {
          userId: route.userId,
          messageId: message.id,
          dmJid: message.chatJid,
          caption: route.media.caption,
          occurredAt: message.timestamp.toISOString(),
        };
        void track(
          session
            .downloadMedia(message.id)
            .catch(async (error: unknown) => {
              console.error("media download failed, parking", error);
              await parkQueue.enqueue({
                kind: "retrySnapshot",
                payload: snapshotPayload,
                opId: `park-snapshot:${message.id}`,
              });
              throw error; // stop the chain here; the park above is the durable record
            })
            .then((bytes) =>
```

(the remainder of the `.then((bytes) => ...)` body from Step 3 is unchanged; only prepend the `.catch` above it and close with `.catch((error: unknown) => console.error("snapshot capture failed", error));` as before — the outer catch now also swallows the re-thrown download error after it has already been parked, so nothing propagates as an unhandled rejection.)

Add the drain handler for `retrySnapshot` in `replay()`'s `parkQueue.drain(async (op) => { ... })` callback. Currently it unconditionally treats every op as `retryExtraction`; branch on `op.kind`:

```ts
await parkQueue.drain(async (op) => {
  const attempts = op.attempts ?? 0;
  if (attempts >= MAX_PARK_ATTEMPTS) {
    console.error(
      `giving up on ${op.kind} after ${attempts} attempts; quarantining`,
    );
    await quarantine.enqueue(op);
    return;
  }
  if (op.kind === "retrySnapshot") {
    const payload = op.payload as {
      userId: number;
      messageId: string;
      dmJid: string;
      caption: string | null;
      occurredAt: string;
    };
    await track(
      session
        .downloadMedia(payload.messageId)
        .then((bytes) =>
          runSnapshotCapture(
            {
              userId: payload.userId,
              dmJid: payload.dmJid,
              bytes,
              caption: payload.caption,
              occurredAt: new Date(payload.occurredAt),
            },
            {
              repo,
              ocr: { extractText: (b) => extractText(b) },
              extractor,
              sharedOwnerUserId: cfg.sharedOwnerUserId,
              participantUserIdFor: (id) => participantUserId.get(id),
              otherUserName:
                cfg.users.find((u) => u.userId !== payload.userId)
                  ?.displayName ?? "the other user",
            },
          ),
        )
        .then(async (out) => {
          if (out.ackText) {
            privateReplyWindow.record(payload.dmJid, out.storedIds);
            await session
              .sendText(payload.dmJid, out.ackText)
              .catch((e: unknown) => console.error("ack send failed", e));
          }
        })
        .catch(async (error: unknown) => {
          console.error("retrySnapshot failed, re-parking", error);
          await parkQueue.enqueue({
            kind: "retrySnapshot",
            payload: op.payload,
            opId: op.opId,
            attempts: attempts + 1,
          });
        }),
    );
    return;
  }
  await track(capture(op.payload as CaptureBatch, attempts));
});
```

- [ ] **Step 6: Typecheck and run the full suite**

Run: `pnpm test`
Expected: PASS. This is the widest-reaching task in the plan — if `pnpm typecheck` surfaces a mismatch (e.g. a `Repository` fake in an unrelated test file now missing `setVisibility`), add a `setVisibility: vi.fn(async () => true)` line to that fake's object, matching the existing convention every other repository method already follows in `tests/pipeline.test.ts`'s `repo()` helper and any other file constructing a `Repository` object.

- [ ] **Step 7: Manual verification checklist**

This is the one integration point genuinely outside the automated suite — record the outcome in the task's completion notes rather than skipping it silently:

1. Run `pnpm dev` against the real bot on macstudio.
2. Send a real screenshot of a LinkedIn profile to the bot's DM.
3. Confirm the bot replies with the "Read a profile for ... Saved as shared" acknowledgement within a reasonable time.
4. Reply `private` and confirm the person's `visibility` flips (`SELECT visibility FROM prmm.people WHERE canonical_name = '...'`).
5. Send a group image and confirm nothing happens — no reply, no reaction, no row written.
6. Check the OCR engine actually used (`console.log` in `extractText` already reports it) — Vision is expected on macstudio; if tesseract fired instead, note it, since that changes expected accuracy.

- [ ] **Step 8: Commit**

```bash
git add src/index.ts src/store/repository.ts src/store/pg-repository.ts src/store/queued-repository.ts
git commit -m "feat: wire the snapshot route, private-reply correction, and media-download retry into index.ts"
```

---

## Deviations from the design spec, and why

The design spec (`docs/superpowers/specs/2026-07-27-snapshot-ocr-capture-design.md`) sketched `InboundMessage.media` as `{ data: Buffer; mimetype: string; caption: string | null }`, produced synchronously by `normalize.ts`. That does not work: fetching image bytes from WhatsApp's CDN is an async, Baileys-specific operation (`downloadMediaMessage`, keyed on the raw message object, not the mimetype/caption alone), and `normalizeMessage` is a pure synchronous function today with no access to the network or the Baileys socket. This plan keeps `media` on `InboundMessage` to `{ mimetype, caption }` only and adds `WhatsAppSession.downloadMedia(id)` (Task 2) to fetch bytes on demand, only for messages that actually become a `snapshot` route — which also avoids downloading every group image that gets ignored anyway. `types.ts` stays Baileys-agnostic, matching how `MessageKeyLike` already keeps just enough shape to react to a message without leaking Baileys' proto types further than `transport/`.
