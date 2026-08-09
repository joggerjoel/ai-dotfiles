# Snapshot Capture — OCR for Profiles, Badges, and Cards

**Status:** Design approved, ready for planning
**Date:** 2026-07-27
**Follows:** [Phase 1.5 — observability and answering](2026-07-26-phase-1.5-consolidation-design.md)

## Goal

Right now the only way to teach the bot about User B is to type it. That is a hard
limit when the source is a LinkedIn profile, a conference badge, a business
card, or a programme bio — and worse on a phone, where LinkedIn blocks
copy-paste from its own app. This phase lets a screenshot become a fact: DM the
bot an image, it reads the text, extracts a person, and stores what it found —
the same way a typed message does today.

## Why DM, not the group

A screenshot is being used here as a convenient _input_ channel — a way to get
text out of an app that will not let you copy it — not as a request for
secrecy. But the group is where both users are present in real time, and
posting "read a profile for Priya Raghavan" into a live conversation neither
started is a different kind of interruption than a typed capture, which the
group is already used to. DM keeps the input private to the sender without
implying the _output_ should be. See Visibility below for why the stored fact
still defaults to shared.

## Scope

**In scope**

- One image per DM message, sent by either user, OCR'd and extracted
- Profiles, badges, business cards, programme bios — anything that is a
  description of a person rather than a conversation
- A `private` reply immediately after a capture, to override the shared default
- OCR via macOS Vision (primary) or tesseract (fallback), no new dependency

**Out of scope**

- Group images. A screenshot posted to the group is silently ignored this
  phase — a different consent story than a DM, not designed here.
- The stateful correction loop — "actually she's at Meridian now" resolving a
  posted draft. See Phase B below.
- Multiple images in one message, or a caption-driven multi-person extraction
  from one screenshot (e.g., a team page). One image, one primary subject.
- Video, audio, or documents. Baileys' `imageMessage` only.

## What already exists

Everything downstream of extraction is unchanged and reused as-is:

| Module          | Role here                                                                                                                      |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `resolve/`      | `scoreCandidate` runs on the extracted `PersonCandidate` exactly as it does for a transcript mention — no new resolution logic |
| `store/`        | `captureMemory`, `upsertPerson`, the write-ahead queue, `write_ops` — untouched                                                |
| Acknowledgement | The existing 📌/⚠️/🛑/🚫/❓ reaction table already covers every status this pipeline can report                                |

Three things are new: the media path through `normalize`/`router`, an `ocr/`
module, and a second extraction prompt. Nothing else moves.

## Decisions

| Decision           | Choice                                                   | Rationale                                                                                                                                                        |
| ------------------ | -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Channel            | DM only, either user                                     | Own-DM is already the trusted-input channel; group images need a separate consent design                                                                         |
| Visibility default | `shared`, announced                                      | The content is usually public professional information; a private default would silently under-populate the group's shared memory for no reason the sender chose |
| Override           | Bare-word `private` reply, immediately after the capture | Matched by exact content before the mention gate, not addressed to the bot — see Why not `@bot private`                                                          |
| OCR engine         | macOS Vision primary, tesseract fallback                 | The bot runs on macstudio (26.5); Vision reads UI screenshots more reliably than tesseract on mixed fonts and low contrast                                       |
| Extraction         | New prompt, same `ExtractionResultSchema`                | A profile has no speakers, so the transcript prompt cannot be reused; the output shape does not need to change                                                   |
| Draft store        | Deferred to Phase B                                      | `clarifications` is the natural fit, but nothing consumes it yet — see Phase B                                                                                   |

### Why not `@bot private`

The natural instinct is to require addressing the bot, matching the mention
gate's own rule that a bare `@bot` message is a question. But `private` here
is not a question — it is a correction to the capture that just happened,
directed at the specific row the bot just announced, not a general query. Its
scope is narrow enough that a collision is unlikely (an ordinary reply
consisting of exactly the word "private," sent as the very next DM message
after a capture) and the cost of a false match is small — worst case, the
sender's next unrelated message flips a visibility bit they can flip back by
saying `shared`. Requiring `@bot private` would make the one-tap correction
this phase promises into a two-part phrase, for a collision risk narrow enough
not to justify it.

## Architecture

```
DM image → normalize.ts (media survives) → router.ts (snapshot route, own-DM only)
  → ocr/ (new)         Vision | tesseract → raw text
  → extract/            snapshot-prompt.ts → ExtractionResult
  → resolve/             scoreCandidate (unchanged)
  → store/                captureMemory / upsertPerson (unchanged)
  → reaction              existing acknowledgement table (unchanged)
```

## Transport changes

**`normalize.ts`.** `InboundMessage` gains an optional field:

```ts
export type MediaPayload = { data: Buffer; mimetype: string; caption: string | null };
media?: MediaPayload;
```

`MediaPayload` is the type referenced by the router and OCR signatures below —
optional on `InboundMessage` (most messages carry no media), but always
present by the time a `snapshot` route exists, since the route is only
constructed when `media` is set.

The drop guard changes from "no text → drop" to "no text and no media → drop."
Baileys' `imageMessage` carries an optional caption, which rides along as
context for extraction — "this is User B's new boss" alongside the image tells the
extractor something OCR text alone cannot.

**`router.ts`.** `Route` gains one variant:

```ts
| { kind: "snapshot"; userId: number; media: MediaPayload; caption: string | null }
```

Gated identically to the existing `dm` branch — `isOwnDm` only, checked before
the text-question branch so an image never falls through to a text-only path.
A group image, or a DM image from anyone other than the two allowlisted users,
is `ignore`d — the same silent-but-logged drop every other unclassified input
gets today.

## OCR

New module, `ocr/`, one exported function:

```ts
extractText(media: MediaPayload): Promise<{ text: string; engine: "vision" | "tesseract" }>
```

macOS Vision runs via a small native shim (text recognition only, no object
detection needed). Tesseract 5.5.2 is the fallback for a non-macOS host,
invoked the same way any other CLI dependency in this project is — no new
package. An image that yields no text (blank, corrupted, or genuinely not
text-bearing) returns `{ text: "", engine }`; the pipeline treats that as it
already treats a batch that yields nothing extractable.

## Extraction

New file, `extract/snapshot-prompt.ts`, alongside the existing transcript
prompt. The two cannot share a prompt: `prompt.ts` opens with a `Speakers:`
roster and instructs the model to attribute statements to the person who said
them — a business card has no speaker, and reusing that framing would ask the
model to invent a conversation around a profile, which is exactly how a
hallucinated person gets created. The snapshot prompt opens instead with:
"This text was read from an image the user sent by OCR. It describes a person,
not a conversation between people. Do not treat the sender as the subject
unless the image is clearly a selfie or self-introduction."

The output stays `ExtractionResultSchema`-shaped — no schema change. A profile
maps to one `PersonCandidate`, with the headline/title text folded into
`context` (the schema has no dedicated `title` field, and one is not needed:
`context` already carries free text today, just usually less of it than a
profile screenshot yields). A profile with a narrative element — "15 years in
ops, previously at Halvorsen" — additionally yields a `MemoryCandidate` about
that person, exactly as a transcript would.

## Visibility

Snapshot captures set `visibility: 'shared'` on the person and on any memory
candidate, the opposite of DM capture's `'private'` default elsewhere in the
system. The acknowledgement always states this, so the default is never a
silent surprise:

> Read a profile for **Priya Raghavan** — Director of Ops at Halvorsen. Saved
> as shared; User B can see this. Reply `private` to restrict it.

Saying `private` as the very next message flips the just-created row(s) to
`visibility: 'private'`, owned by the sender. The mechanism is deliberately
the lightest thing that works: an in-memory, single-slot map keyed by DM
`chatJid`, holding the ids written by that DM's most recent snapshot capture.
Any other message in that DM — including a second image — overwrites or
clears the slot, and a bot restart empties the map entirely. This is not
`clarifications`, not a database row, and not durable; it is exactly the "did
this just happen" state needed for a one-word correction to the thing that
just happened, no more. A `private` said after the window has closed (another
message intervened, or the bot restarted) falls through to the "no preceding
capture" case below — an unremarkable miss, not a data-loss risk, since the
capture it would have corrected is already stored as `shared` and can still be
fixed later, just not with this one-word shortcut. There is no "correct the
capture from ten minutes ago" in this phase; that waits on Phase B.

## Error handling

| Failure                                                                   | Response                                                                                                            |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| OCR yields no text                                                        | `parked`, same status and reaction (🛑) as a failed transcript extraction                                           |
| OCR text yields no candidate above the confidence floor                   | `refused`, same as any extraction with nothing usable                                                               |
| Vision unavailable (non-macOS host, or the shim fails)                    | Fall through to tesseract; log which engine actually ran, since OCR quality differs materially between them         |
| Media download from WhatsApp fails                                        | `parked`, retried through the existing retry queue — the same mechanism a failed transcript extraction already uses |
| `private` reply arrives with no preceding snapshot capture in the same DM | Ignored; it is not a command outside that context, just an ordinary message                                         |

No new failure category. Every path here maps onto a status the pipeline
already reports and a reaction the acknowledgement table already defines.

## Testing

- `normalize`: an `imageMessage` with no text produces an `InboundMessage`
  with `media` populated, where today it returns `null`; a caption present on
  the image survives into `media.caption`
- `router`: a DM image from an allowlisted user routes to `snapshot`; a group
  image is `ignore`d; a DM image from an unknown sender is `ignore`d
- `ocr`: fixture images — a clear LinkedIn-style screenshot, a low-contrast
  badge photo, a blank image, a non-text photo — each against expected
  text or an empty string, and the correct engine reported
- `extract`: golden fixtures pairing OCR'd text against expected
  `ExtractionResult`, mirroring the existing transcript-fixture pattern in
  `extract/`; include one fixture where the sender's own name appears in the
  image, asserting they are not extracted as the subject
- Visibility: a snapshot capture stores `shared`; a `private` reply
  immediately after stores `private` instead; a `private` reply with no
  preceding capture does nothing
- Integration: one real screenshot through the full path against the
  ephemeral/disposable Postgres pattern established in Phase 1.5, not the live
  `voice` database

## Phase B: the correction loop

Deferred, not designed here. The shape sketched during brainstorming — the bot
posts a draft, the user corrects it in plain language, `clarifications`
resolves the row — remains the plan, and `clarifications.kind='fact'` already
fits it without a schema change. It waits on Phase A landing first: this
design has no way yet to say what OCR quality actually looks like against
real screenshots, and that answer should shape how much correction machinery
is worth building. `clarifications` stays unread by production code until
Phase B gives it a consumer.

## Open questions

- Should a caption alone (no image) ever trigger anything, or is a captionless
  image always required to enter this path?
- If OCR misreads a name badly enough that resolution creates a wrong new
  person, is there a fast undo, or does that wait on Phase B's correction
  loop too?
- Does `private` need a matching `shared` command for the reverse correction,
  or is that already Phase B's territory?
