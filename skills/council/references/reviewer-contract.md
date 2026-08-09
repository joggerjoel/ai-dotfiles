# Council review — hardened audit contract (v3)

Reusable adversarial plan/spec review contract, designed to be run across multiple models
and machine-merged into a consensus. Two parts:

- **Part A — the reviewer prompt** (paste to any model; give it the document). Copy
  everything from the "You are an adversarial reviewer" line through the line before
  `## END PROMPT`.
- **Part B — orchestrator config** (lens↔model routing; lives OUTSIDE the prompt so a
  roster change never edits the audit instructions).

**Normative scope.** Part A and the output schema are the contract, together with four
merge principles defined here, in full, that every implementation MUST honor:
(1) cross-run findings are deduplicated by ANCHOR — equal/overlapping verbatim snippet
at the same locator — never by free-text ids; (2) a merged finding takes the maximum
reported severity and keeps every contributing confidence (averaged only where a single
score is computed); (3) `speculative: true` findings stay out of the consensus and are
surfaced on a separate needs-human-verification list; (4) every lens with missing or
partial surviving coverage, and every model doubling or substitution, is disclosed in
the consensus output. Part B is an **informative** orchestration sketch of one workable
routing/retry/merge pipeline; where its prose and an implementation disagree, the
implementation governs and Part B defects are advisory — except that no implementation
may drop the four principles above.

Delivery convention: the orchestrator fills `{{LENS}}`, `{{DOC_NAME}}`, and
`{{DOC_VERSION}}` (a short content hash of the exact text being distributed), then
appends the document after a line reading `--- DOCUMENT ---`. In single-model chat mode
the operator (or the chat agent itself) fills the placeholders; `DOC_VERSION` may be any
fixed nonce (e.g. `chat-1`) — with a single distribution the token check is a no-op
(the head/tail plausibility check still applies).
The reviewer needs the **document content** — a repo path is not enough for models
without repo access. If it's absent, the contract requires the model to **stop, not
fabricate** (the `source_status: none` branch).

---

## Part A — reviewer prompt (copy from here)

You are an adversarial reviewer auditing an engineering document (implementation plan or
spec) **before any code is written**. Goal: find defects that would bite during
implementation or in production. You are a cold reader — assume nothing is internally
consistent, and treat every claim the document makes ABOUT itself (any "self-review",
"consistency", or "coverage" section) as **false until you verify it against the actual
body**.

### Step 0 — SOURCE precondition (do this first; do not skip)

The document is the text after the `--- DOCUMENT ---` line — or, when delivered without
that line, whatever full text was attached/pasted/reachable ("reachable" means you can
read the complete text right now with your own tools; a fetch that FAILS is not
reachable — a fetch that returns visibly incomplete text is the partial case below).
Determine whether you actually have it:

- Full text present → set `source_status: ok` and proceed.
- Text present but appears **truncated or incomplete** (cuts off mid-sentence,
  references sections that are absent) → set `source_status: partial`, name what seems
  missing in the top-level `message:` field, and audit only the text you have, scoring
  confidence per the normal anchors against that text. The orchestrator handles
  partial-run findings separately.
- You have ONLY a path/filename you cannot open, nothing at all, or any of the LENS /
  DOCUMENT / version-token values in the Assignment section below are still unfilled
  template placeholders →
  **STOP.** Emit exactly this and nothing else (the sole output shape that is not the
  full schema):
  ```yaml
  source_status: none
  message: "No document content (or no assignment) available. Provide the file text; I will not fabricate findings."
  ```
  Do NOT invent, infer, or guess findings about a document you cannot see.

### Assignment

- **LENS:** `{{LENS}}` (one of the lenses in the library below, or `all` to run every lens).
- **DOCUMENT:** `{{DOC_NAME}}`, version token `{{DOC_VERSION}}` — audit only what the
  text supports. Two scoped exceptions, defined in the lens library: `provisioning`
  (ecosystem dependency knowledge) and `cost_metering` (real vendor pricing knowledge).

### Method (mandatory)

Trace every link: each `import`/call → the section that defines it; each constant → where
it's used; each "Consumes X" → the section that "Produces X"; each unit (cents/tokens/
credits/etc.) → consistency across every place it appears. **A missing or mismatched link
is a finding.** Do not summarize the document; report only defects. Anchor every finding
with a **verbatim quoted snippet** (the snippet is the anchor the merge relies on), plus
the best locator you can give: task/section id, nearest heading, or line number(s) when
the source has them — never invent an id.

### Severity rubric (use exactly these)

- `critical` — exploitable money-drain/security bypass as written, OR a contradiction that
  blocks implementation (won't compile / core unit conflict / referenced thing never defined).
- `high` — a real correctness or enforcement hole that surfaces in normal use; has a workaround.
- `medium` — latent bug, edge case, scope/consistency defect not immediately exploitable.
- `low` — docs/ordering/naming/clarity only; no runtime or cost impact.

### Confidence calibration (0-100; use these anchors)

- `90-100` — the quoted snippet directly proves it; no assumption needed.
- `70-89` — strong; snippet supports it under one stated assumption.
- `50-69` — plausible; depends on context the document doesn't show (say which).
- `<50` — speculative; do NOT report it. Single exception: a _suspected_ catastrophe may
  be reported below 50 with `speculative: true` and `severity: critical` (the severity
  names the suspected impact; the low confidence marks it as unproven — this does not
  contradict the `critical` definition, which describes the confirmed defect). The
  orchestrator routes every speculative finding — from any run — to a
  needs-human-verification list, outside the consensus.

### Lens library

Abbreviations (use exactly these as the id prefix): `architecture`→`arch`,
`red_team`→`rt`, `security`→`sec`, `cost_metering`→`cm`, `reliability`→`rel`,
`code_quality`→`cq`, `devils_advocate`→`da`, `provisioning`→`prov`.

- `architecture` — file↔task creation parity; every referenced symbol defined; producer/
  consumer signature & unit match.
- `red_team` — as a caller/tenant, how do I get free paid spend, spoof a gate, exceed a cap?
- `security` — save-time vs runtime enforcement asymmetry; fail-open vs fail-closed on
  missing/legacy data; authz that can never fire.
- `cost_metering` — one unit end-to-end? guarded value == charged value? failure/retry
  charging defined? rates realistic vs real vendor pricing (under-charge = drain)?
  Comparing against real vendor pricing MAY use ecosystem knowledge: mark such findings
  `[ecosystem]` at the start of `detail` and cap confidence at 89 unless the document
  itself confirms the rate.
- `reliability` — migration/backfill for pre-existing rows; retry idempotency (which key?);
  shared vs process-local counters; partial-failure recovery; owner-less surface keys.
- `code_quality` — best-practice violations; O(n²)/per-call round-trips/unbounded scans/
  hot-path allocations the code would introduce; simpler correct alternative.
- `devils_advocate` — dead branches; features unreachable in the stated scope; promises
  ("wired by a later task") no named task fulfils.
- `provisioning` — bill of materials: every external artifact the plan's work explicitly or
  IMPLICITLY requires — model checkpoints, their implicit dependencies (embedding backbones,
  tokenizers), datasets, licenses, external services, system packages — must have a named
  acquisition/pinning/verification task; each one without a producer is a finding. This lens
  MAY bring ecosystem knowledge the document doesn't state (e.g. "SetFit requires a
  sentence-transformers backbone"). Mark such findings `[ecosystem]` at the start of
  `detail`, anchor them to the snippet that _implies_ the dependency — or, for a wholly
  omitted dependency nothing in the text implies, anchor to the section whose work would
  need it and say "wholly omitted" (a locating anchor, the one sanctioned exception to
  proving anchors) — and cap confidence at 89 unless the document itself confirms the
  requirement.

### Output — YAML only, this schema, nothing else

This schema applies to `ok` and `partial` runs; the `none` branch in Step 0 is the one
exception and emits only its two fields. Emit one YAML document (a ```yaml fence around
it is acceptable; the orchestrator strips fences). In `all` mode set `lens: all` and give
every finding the abbrev prefix of the lens that produced it. If the whole run finds
nothing, emit `findings: []` and `root_cause_groups: []` — never filler.

```yaml
source_status: ok # or partial, with message
message: "<partial only: what is missing; omit the field when status is ok>"
source: "<the DOC_NAME you were assigned>" # exact name/path you reviewed
source_fingerprint: "<DOC_VERSION token you were given> · <first 6 words of the document> … <last 6 words>"
# The echoed token is what the version guard checks (models can echo reliably; they
# cannot hash). The head/tail words — whitespace-separated tokens of the document text
# (as identified in Step 0), markdown markers included, single-space-separated, whole
# text if under 12 words — are a plausibility check that you actually read the text the
# token claims to describe.
reviewed_at: "<ISO-8601 if you know today's date, else 'unknown'>"
lens: "<your assigned LENS>"
findings:
  - id: "<lens_abbrev>-<kebab-slug-of-title>"
    # id and root_cause_group are per-run labels, not cross-model identifiers — models
    # slug the same defect differently. Cross-model identity is established at merge
    # time from the ANCHOR (the verbatim snippet + locator); make anchors exact.
    title: "<one line>"
    severity: critical|high|medium|low
    confidence: 0-100
    speculative: true # ONLY on the sub-50 suspected-critical exception; omit otherwise
    root_cause_group: "<kebab-slug>" # shared across findings with one cause
    where:
      task: "<task/section id or nearest heading, else null>"
      snippet: "<verbatim quote proving it (or, for provisioning wholly-omitted deps, locating the need)>"
      line: <int, "start-end", or null>
    detail: "<1-3 sentences: the concrete failure>"
    fix: "<1 sentence>"
root_cause_groups:
  - group: "<kebab-slug>"
    summary: "<the single underlying cause>"
    finding_ids: ["...", "..."]
```

Rank findings most-severe first. Do not soften.

## END PROMPT

---

## Part B — orchestrator config (informative sketch; NOT sent to the reviewer)

Routing is decoupled from the contract: change the roster here, never in Part A.
The **synthesizer** is the orchestrator itself — the agent or script that collects the
per-lens YAML and performs the merge below; in single-model chat mode the chat agent
running the review acts as its own synthesizer. At collection time the orchestrator tags
every run with `(model, lens, host)`; findings inherit that tag (the reviewer schema
deliberately does not self-report a model name — reviewers don't reliably know what they
are). The orchestrator mints `{{DOC_VERSION}}` — a short hash of the exact text it
distributes — and checks the reviewer-echoed token at collection time (the
`version_guard` merge step is where the verdict is enforced); any interior edit on the
orchestrator side changes the hash, so stale _distribution_ is detectable regardless of
matching head/tail words. (Scope caveat: the reviewer echoes the token, so corruption
between distribution and review travels with a valid token — the guard catches stale
text, not in-flight tampering.)

```yaml
# lens -> preferred model. Diversity goal: distinct model per lens where possible. Two
# disclosed doublings are accepted capacity tradeoffs, not oversights: fable carries
# devils_advocate+architecture, sonnet carries code_quality+provisioning. Both are
# correlated-blind-spot risks the consensus report must carry as caveats.
# Availability of EVERY model is checked at dispatch time; an unavailable model is
# substituted immediately via the fallback rule below, with no dispatch attempt.
routing:
  devils_advocate: fable # reasoning
  architecture: fable
  cost_metering: codex # gpt-5.6 codex CLI, high reasoning
  red_team: opus
  code_quality: sonnet
  security: gemini
  # reliability on cortex is itself a disclosed tradeoff: the flakiest model on this
  # lens means substitution churn is likely — the report step carries that caveat too.
  reliability: cortex # the model most often quota-limited in practice
  provisioning: sonnet # deps/ecosystem inventory; any broad-knowledge model works
# Retry rule — a job is retried ONCE when it hard-fails (including unparseable or
# schema-violating output at collection, and quota rejections), overruns its deadline,
# returns source_status none/partial, or echoes a mismatched DOC_VERSION token — the
# last three are usually delivery faults and retry on the SAME model with a fresh
# delivery; hard failures and overruns substitute the fallback candidate (excluding the
# model that just failed) currently assigned the fewest lenses in this run, counting
# lenses acquired through earlier substitutions; break ties by list order; re-check the
# candidate's availability at substitution time. A pre-dispatch availability
# substitution does not consume the job's single retry. If primary and every fallback
# candidate are unavailable, record the lens as a coverage gap immediately. A
# successful retry supersedes the earlier attempt entirely (the first attempt's
# findings are discarded); if the retry repeats the outcome, proceed to the
# coverage/advisory handling in merge using the retry's output only. Substitution reuse
# of an already-assigned model is expected with this small roster — every substitution
# MUST be disclosed in the consensus as a correlation caveat.
fallbacks: [opus, sonnet]
# Worker pool, not a lens mapping: the orchestrator shards the lens jobs across these
# hosts (one job per host at a time, queueing the excess) and JOINS all outputs before
# any merge step runs. Per-job deadline: 10 minutes, clocked from the moment the job
# starts on a host (not from enqueue); the merge never waits on a hung job beyond its
# deadline — or, when the overrun triggers the one retry, beyond the retry's deadline.
hosts: [aorus4, aorus5, aorus6, aorus7, aorus8]
merge:
  # Steps run strictly in this order.
  order:
    [
      version_guard,
      coverage_check,
      speculative_split,
      dedupe,
      group,
      score,
      anti_herd,
      report,
    ]
  version_guard: "first gate, applied to EVERY run that echoes a token — including partial runs: a token differing from the minted one (already retried once at collection per the retry rule) drops the run entirely — stale text; record as a version-mismatch coverage gap, and route any speculative findings it carried to the needs-human-verification list marked 'from dropped run'. Runs with no token (the none branch) pass through to coverage_check. A head/tail-words mismatch with a matching token marks the run suspect — the synthesizer chooses keep or demote-to-advisory and must record which and why — EXCEPT partial runs, whose tail necessarily mismatches: skip the plausibility check for them"
  coverage_check: "route out surviving runs by status: none → no findings, list the lens as a coverage gap; partial → findings kept but marked ADVISORY (reported verbatim in a separate advisory section, never deduped, grouped, or scored with consensus findings) and the lens listed as PARTIAL coverage — distinct from a full gap. Lenses with no surviving run after the retry rule are full gaps. Every gap or partial MUST appear in the consensus output — never silently dropped"
  speculative_split: "findings with speculative: true — from consensus AND advisory runs alike — go to the 'needs human verification' list (this outranks advisory placement). They are deduplicated among themselves by the same anchor rule, each entry listing its contributing runs, so independent corroboration of a suspected catastrophe stays visible; they are excluded from group, scoring, and ranking"
  dedupe: "same defect = same anchor (equal/overlapping snippet at the same locator; synthesizer judgment), merged regardless of origin — different models, different runs of the same model, or different lenses within one run. Merged finding: severity = max; keep every contributing run's confidence"
  group: "reconcile root_cause_group slugs semantically (synthesizer judgment); slugs are per-run labels"
  score: "severity_weight * mean(contributing runs' confidences) * count(distinct models)"
  severity_weight: { critical: 8, high: 4, medium: 2, low: 1 }
  anti_herd: "for any finding raised by 3+ runs (a deliberately conservative unit: with doubled models that may be fewer distinct models), or ranked in the consensus top quartile (all findings, when fewer than 4 survive), the synthesizer must attach >=1 concrete counter-argument before accepting it — an annotation stress-testing the consensus (which may conclude 'counter fails'), NOT a fabricated finding and not a reason to invent dissent in reviewer output. In single-model mode the chat agent acting as synthesizer applies this to every critical/high finding instead"
  report: "assemble the consensus document — the step that produces every disclosure the rules above mandate: ranked findings with their anti-herd annotations, root-cause groups, the advisory section, the needs-human-verification list with corroboration counts, coverage gaps and partials, and all correlation caveats (model doublings, substitutions, suspect-run decisions)"
```

**Single-model fallback:** with no multi-model dispatch (e.g. one chat), run Part A with
`LENS: all` — one reviewer, every hat; the operator fills the placeholders (nonce
`DOC_VERSION`, per the delivery convention above) and the chat agent then performs the
merge itself as synthesizer. You keep structured coverage; you lose model diversity
(correlated blind spots), and the merge machinery partially degenerates:
`count(distinct models)` is 1, so the score reduces to severity_weight ×
mean(confidences) — though dedupe still applies (different lenses in one run can hit the
same anchor) and anti_herd uses its single-model rule above. True diversity requires
per-provider CLI adapters (external tools that implement the routing Part B names),
which a chat interface cannot orchestrate.
