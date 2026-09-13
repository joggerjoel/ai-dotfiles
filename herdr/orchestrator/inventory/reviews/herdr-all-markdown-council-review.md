# Herdr Markdown council review

> Historical review imported on 2026-09-13. This describes the source version audited then,
> not current implementation status. See the [current resolution](../../merge-busybrain-herdr-council-resolution.md)
> and [build guide](../../guides/building-herdr.md). Quotes and finding IDs are preserved.
> Local navigation links were made repository-relative and stale line suffixes removed;
> those links open current files, not frozen audited copies. Fingerprints identify the original
> review input, not this relocated document. External BusyBrain references require its separate checkout.
> The later merge resolution covers only its named 22 entries. Other findings in this broader
> audit require revalidation and disposition; importing this report does not accept or resolve them.


Reviewed 2026-09-13. Source version `9c54377912d1`.

## Scope and method

The source is every Markdown file under `herdr/orchestrator/`, read in lexical order:

- `MACHINE.md`
- `MACHINE.template.md`
- `TODO.template.md`
- `master-control-herdr-plan.md`
- `master-control-herdr-todo.md`
- `merge-busybrain-herdr-council-review.md`
- `merge-busybrain-herdr-plan.md`
- `merge-busybrain-herdr-todo.md`

Eight isolated subagents ran the architecture, red-team, security, cost-metering, reliability,
code-quality, provisioning, and devil's-advocate lenses. All eight returned complete coverage and
the expected fingerprint. One provisioning run first received the wrong working directory. The
same reviewer retried with absolute paths and returned complete coverage. No run was partial,
dropped for version mismatch, or speculative.

All reviewers used the same model. The review has process isolation and eight lenses, but not
model diversity. Consensus scores therefore use one distinct model:

`severity weight × mean confidence × 1`

The report preserves the maximum severity when reviewers disagree. It deduplicates findings only
when their quoted anchors overlap at the same location. Findings with different anchors remain
separate even when they have the same root cause.

## Verdict

The document set is not ready for implementation. Ten critical findings remain. Five prevent the
documented runtime from starting or define contradictory state authority. Three expose operator
credentials or authorization. The remaining two leave initiative creation and machine
configuration without an executable producer.

## Critical findings

### 1. Stale loop budgets block one implementation

- **Severity:** critical
- **Score:** 800
- **Reviewers:** 4 of 8
- **Root cause:** stale lifecycle invariants
- **Anchor:** master plan §10.1, `"Those are bounded by the 3-attempt retry budget, the 3-nudge cap, the 25-injection turn cap, and the 2-reset cap. All five mechanisms are required"`
- **Failure:** Master §6 removes the reset budget and sets 12 injections per attempt. Section
  10.1 still requires two resets and a 25-injection cap. Both statements are normative.
- **Fix:** Delete the obsolete reset and 25-injection rules. Define the current bounds once and
  reference that definition everywhere.
- **Counterargument:** Section 10.1 may describe historical defenses rather than current state.
  That reading fails because the text calls all five mechanisms required.

### 2. First-contact session bootstrap calls a nonexistent command

- **Severity:** critical
- **Score:** 800
- **Reviewers:** 1 of 8
- **Root cause:** stale Herdr CLI contract
- **Anchor:** master plan §7, `"herdr --session <profile> creates a session if none exists"`
- **Failure:** The verified capability table says `herdr --session <name>` does not exist and
  names no working session-creation command. `pane split` requires an existing pane.
- **Fix:** Discover and test the real bootstrap path. Block Phase 3 dispatch until it exists.
- **Counterargument:** Another process might create the first session. The plan does not name that
  process or make it a prerequisite, so the documented bootstrap remains unreachable.

### 3. The fleet poll loop calls `agent status`, which does not exist

- **Severity:** critical
- **Score:** 800
- **Reviewers:** 1 of 8
- **Root cause:** stale Herdr CLI contract
- **Anchor:** master plan §7, `"polling herdr agent status every 5 s"`
- **Failure:** The verified capability table replaces the nonexistent command with
  `herdr agent get <target>`.
- **Fix:** Replace each operational `agent status` reference with the verified `agent get`
  contract and test the poll loop.
- **Counterargument:** The phrase may be descriptive shorthand. It appears inside the normative
  concurrency algorithm and therefore directs implementation.

### 4. The live `MACHINE.md` cannot satisfy the required schema

- **Severity:** critical
- **Score:** 800
- **Reviewers:** 1 of 8
- **Root cause:** incoherent machine configuration
- **Anchor:** `MACHINE.md`, `"Master Control Workspace: /Users/joggerjoel/Developer/herdr/ochestrator"`
- **Failure:** The live file uses a legacy prose shape, omits parser-required fields, and misspells
  `orchestrator`. The roadmap nevertheless marks machine context complete.
- **Fix:** Generate the live file from `MACHINE.template.md`, fill every required value, and make
  parser success a dispatch admission check.
- **Counterargument:** `MACHINE.md` may be informational rather than runtime configuration. The
  master plan explicitly makes machine context a supervisor input, so that interpretation would
  require a different authoritative file.

### 5. Agent-controlled Git configuration crosses the privilege boundary

- **Severity:** critical
- **Score:** 784
- **Reviewers:** 2 of 8
- **Root cause:** incomplete incident privilege boundary
- **Anchor:** master plan §10.4, `"Supervisor git inside that tree is hardened against hooks and repo-local config the agent controls"`
- **Failure:** The hostile incident user owns the clone and `.git/config`. Disabling hooks and
  global configuration does not disable local clean filters, credential helpers, `core.sshCommand`,
  or a replaced remote. Operator-run Git can execute or contact attacker-controlled targets.
- **Fix:** Perform privileged Git operations only in a fresh operator-owned sanitized clone.
- **Counterargument:** Command-line `git -c` options could neutralize individual settings. The
  current plan does not enumerate or prove a complete denylist, and Git configuration has several
  command-execution paths.

### 6. Initiative units have consumers but no producer

- **Severity:** critical
- **Score:** 784
- **Reviewers:** 1 of 8
- **Root cause:** missing initiative intake
- **Anchor:** merge TODO G.6, `"Planner decomposition creates units with separate leases and budgets."`
- **Failure:** No planner, input schema, command, or queue grammar creates initiatives,
  requirements, dependency edges, scopes, or capability requirements. Pieces I and J only store,
  schedule, and display objects that already exist.
- **Fix:** Define the authoritative initiative input and decomposition compiler before scheduler
  implementation.
- **Counterargument:** A human could populate SQLite directly. That bypasses validation and is not
  a supported product entry point.

### 7. `TODO.md` is both authoritative input and generated output

- **Severity:** critical
- **Score:** 784
- **Reviewers:** 1 of 8
- **Root cause:** split state authority
- **Anchor:** merge plan §2.10, `"The Markdown TODO is an operator-friendly projection of requirements. It is not the live status record."`
- **Failure:** Master §2.5 still calls the file authoritative and uses `[>]` lines during restart
  reconciliation. A partial projection write leaves two conflicting recovery authorities.
- **Fix:** Make SQLite authoritative after intake. Define atomic TODO projection and rebuild it
  from SQLite on restart.
- **Counterargument:** TODO could remain authoritative for intent while SQLite owns execution.
  The current documents do not define the transition or resolve conflicting marks after a crash.

### 8. Device approval is not bound to the initiating OAuth client

- **Severity:** critical
- **Score:** 776
- **Reviewers:** 1 of 8
- **Root cause:** unbound OAuth transaction
- **Anchor:** master plan §9.2, `"The captured code is consumed: the extension compares the code shown on the activation page against the one captured from the terminal"`
- **Failure:** A compromised dependency can initiate its own legitimate device flow, print the
  allowlisted URL and matching code, and receive the dedicated account's grant.
- **Fix:** Track a supervisor-initiated provider transaction and verify client ID, account,
  audience, and requested scopes before approval.
- **Counterargument:** The dedicated profile limits the affected account. It does not stop theft
  of that account's authorization or spending capacity.

### 9. Endpoint allowlisting does not bind OAuth client, account, or scopes

- **Severity:** critical
- **Score:** 768
- **Reviewers:** 1 of 8
- **Root cause:** unbound OAuth transaction
- **Anchor:** master plan §9.2, `"The URL's scheme+host+path, query stripped, is in an exact-endpoint allowlist"`
- **Failure:** The approved provider endpoint can serve attacker-initiated flows. The bridge does
  not verify the trusted client identity, audience, scopes, or selected account.
- **Fix:** Add provider-specific trusted request binding and fail closed when the consent page
  cannot prove it.
- **Counterargument:** Exact endpoint and code checks defeat arbitrary phishing sites. They do not
  distinguish two legitimate flows at the same provider.

### 10. Reviewer output can become operator command execution

- **Severity:** critical
- **Score:** 752
- **Reviewers:** 2 of 8
- **Root cause:** untrusted content crosses a command boundary
- **Anchor:** merge plan §2.2, `"The supervisor checks test, path_exists, path_changed, and absence findings with a command it runs itself"`
- **Failure:** Repository text influences the reviewer, and the schema permits a free-form
  `verify_cmd`. A prompt injection can therefore become shell execution in an operator-owned TODO
  verification pane.
- **Fix:** Remove model-authored commands. Convert typed operands into supervisor-built checks and
  allow only configured test commands, executed without a shell.
- **Counterargument:** The reviewer schema restricts the verification kind. It does not restrict
  the command string, executable, arguments, or shell syntax.

## High findings

| Score | Reviewers | Root cause | Anchor and concrete failure | Required fix |
| ---: | ---: | --- | --- | --- |
| 400 | 1 | incoherent machine configuration | `MACHINE.md`: `"Machine Name: Local Mac"`. The live file and template use incompatible schemas. | Replace the legacy file and test the live instance with the production parser. |
| 399 | 4 | candidate identity | Merge §2.2: `"git diff origin/<base_branch>..HEAD"`. Review omits staged, unstaged, and untracked files that the land step later publishes. | Stage the final policy-selected files into an immutable candidate, then verify, scan, review, and land that exact object. |
| 396 | 1 | unsafe alert transport | Master revision note: `"writing untrusted alert bytes through pane run re-introduces shell interpolation"`. Phase 8 does not schedule the acknowledged fix. | Add a binary-safe, non-shell transfer and make it a Phase 8 gate. |
| 396 | 2 | incomplete escalation model | Merge §2.4: `"The class set is closed and small"`. It omits machine-offline, MC-EXIT, push, PR, auth, dependency, and other live failure kinds. | Preserve the master failure kind and define a total mapping to presentation class, ack policy, and timeout. |
| 395 | 3 | fail-open review confirmation | Merge §2.2: `"cannot confirm is logged and demoted to warning"`. Timeout, malformed input, missing tools, and transport failure become permission to land. | Separate confirmed, disproved, and indeterminate. Only disproved findings may be demoted. |
| 394 | 2 | missing runtime commands | Master TODO 3.1 lists `run`, `status`, `ack`, `abort`, and `trust`, but omits the daemon that owns state and `stop`. | Add both commands and socket, unavailable-daemon, and graceful-stop tests to Phase 3. |
| 392 | 2 | unbounded reviewer input | Merge §2.2 sends the whole diff and verifier output with no byte, token, response, or truncation policy. | Set request and response budgets. Escalate or use coverage-preserving deterministic chunks when oversized. |
| 392 | 1 | missing state migration | Merge TODO G.1 extends existing SQLite tables without schema versions, backfills, or crash-safe migrations. | Add transactional versioned migrations and restart tests for every prior state. |
| 392 | 1 | missing system dependency | Master §6 invokes `gh pr create`, but no task installs, pins, authenticates, or preflights `gh`. | Add GitHub CLI and credential-helper provisioning with a push and PR smoke test. |
| 391 | 3 | review state not persisted | Merge §2.2 says a confirmed finding enters the next packet, but `last_failure` reads only verifier state. | Persist review results and add them to validation, packet construction, and restart tests. |
| 388 | 1 | unsafe test trust | Master §6 says an added test file cannot weaken existing assertions. `conftest.py`, plugins, fixtures, and collection hooks can. | Treat executable test infrastructure as a privileged change and verify collection and skip counts. |
| 388 | 1 | run-record schema evolution | Merge TODO F.1 rejects unknown fields, while G through J later add required fields without a version. | Version `RunRecord` and support existing emitted versions. |
| 388 | 1 | machine configuration authority | Master §2 says the supervisor-owned copy supplies values, then other sections inject or fetch a different `MACHINE.md`. | Define one authoritative orchestrator record and separately named agent and remote projections. |
| 388 | 1 | missing daemon provisioning | Merge §2.7 depends on launchd or systemd restart, but no task creates or tests a service unit. | Add install, enable, permissions, environment, reboot, and recovery work for each supported OS. |
| 387 | 3 | outbound screening order | Merge §2.2 sends the diff and verifier output to the reviewer before the land-time secret scan. | Screen and minimize the exact outbound payload before the API call. |
| 384 | 1 | unbounded paid incident queue | Master §8 queues every alert beyond concurrency and hourly caps, then drains the queue automatically. | Bound and expire the queue by source and time horizon. Require approval for overflow work. |
| 384 | 1 | review request restart safety | Merge §2.2 defines no durable request ID or transition for daemon death, timeout, rejection, or malformed output. | Persist the review operation before submission and reconcile it after restart. |
| 382 | 2 | reviewer billing and failure policy | Merge TODO C.4 promises one Messages request but does not define whether an ambiguous billed call may be resent. | Store idempotency and billing state. Define known-billed, known-unbilled, rejected, and ambiguous outcomes. |
| 380 | 3 | non-atomic run closure | Merge §2.6 closes in SQLite and appends `units.jsonl` separately without a publication marker. | Store the canonical record in SQLite and export JSONL idempotently by unit ID. |
| 376 | 2 | quota unit mismatch | Merge §2.8 reserves unspecified `estimated use` against provider percentages. | Define quantities and denominators per limit ID and reject proactive admission without conversion. |
| 376 | 1 | missing monetary cap | Master §9.1 requires a hard spend cap for API billing, but the mandatory reviewer adds no cap field or gate. | Require a local cap or verified provider-side hard cap before API review is enabled. |
| 376 | 1 | unresolved billing reservation | Merge §2.8 can retain an unknown billed reservation forever when the provider has no usage API. | Add an owned resolution workflow, conservative expiry, operator adjudication, and `next_action_at`. |
| 376 | 1 | missing notification service | Master §5 selects self-hosted ntfy, but no task deploys, authenticates, enrolls, or tests it. | Add pinned ntfy and phone-client provisioning with a delivery failure test. |
| 368 | 1 | missing browser runtime | Master §9.2 requires Chrome profiles, accounts, and an extension without a provisioning owner. | Add per-machine Chrome, profile, entitlement, extension, and isolation setup. |
| 360 | 1 | reactive usage is unbounded | Merge §2.8 serializes calls when usage is unknown, but does not limit sequential tokens, requests, or dollars. | Require a local request, token, or dollar budget for reactive mode. |
| 358 | 2 | replayed paid work | Master §11.2 admits body-only-HMAC webhooks can be replayed after 24 hours. | Add a relay-authenticated timestamp and delivery ID with durable freshness enforcement. |
| 352 | 1 | missing mail verification dependency | Master §8 requires DKIM and DMARC alignment, but no library or service supplies them. | Select, pin, provision, and test a verifier and DNS dependency. |

### Anti-herd checks for repeated high findings

- **Candidate identity:** A disciplined worker could commit everything before review. The lifecycle
  explicitly allows uncommitted and untracked output, so correctness cannot depend on discipline.
- **Review confirmation:** Most failures may be true disprovals. The contract does not distinguish
  them from infrastructure errors, so fail-open behavior remains reachable.
- **Review persistence:** The action log might reconstruct the result. Packet construction is not
  specified to read or validate that log as review state.
- **Outbound screening:** Provider-side retention controls could limit impact. They do not prevent
  the initial secret disclosure.
- **Run-record publication:** Duplicate JSONL lines could be deduplicated during reads. The stated
  invariant is one record per unit, and missing appends cannot be repaired without a durable marker.

## Medium and low findings

| Severity | Score | Reviewers | Finding | Required fix |
| --- | ---: | ---: | --- | --- |
| medium | 200 | 1 | The Phase 5 baseline requires the BusyBrain watchdog to stop, but the work remains under `Not scheduled`. | Create an owned pre-Phase-5 retirement task and verify both jobs stay stopped. |
| medium | 200 | 1 | The run record promises time to first verifier but records no verifier start timestamp. | Add `verifier_started_at` and its aggregation test. |
| medium | 196 | 1 | The dataclass and JSON schema sync test compares only property names. | Run one positive and negative corpus through both complete validators or generate one from the other. |
| medium | 195 | 2 | `scope:` is an enforcement field with no delimiter, glob dialect, normalization, directory, or traversal rules. | Specify the grammar and add parser-to-land path tests. |
| medium | 195 | 2 | The reviewer example expects grep exit 1 for health, while acceptance confirms the defect at exit 0. | Define confirmation polarity and error outcomes for each check kind. |
| medium | 192 | 1 | The versioned price schedule has no acquisition, effective-date, update, or validation task. | Add an authoritative price-ingestion and reconciliation task. |
| medium | 188 | 1 | `RunRecord.final` cannot represent skipped, aborted, archived, or still-blocked units. | Separate terminal disposition from failure class. |
| medium | 180 | 1 | The terminal-noise normalizer removes digits and whitespace from semantic verifier evidence. | Use a separate structured evidence canonicalizer. |
| medium | 180 | 1 | SMTP replies have no provider, credentials, TLS, sender identity, or delivery test. | Add an incident-mail provisioning prerequisite. |
| medium | 178 | 1 | One `cached tokens` field cannot reproduce cache-write TTL, hit, service-tier, or long-context pricing. | Store each vendor billing category returned by the provider. |
| medium | 176 | 1 | Transfer and integration are omitted from the idempotent operation list. | Add operation IDs and commit compare-and-swap rules around every Git and SQLite boundary. |
| medium | 174 | 1 | `.tar.zst` recovery requires tar Zstandard support or `zstd`, but no prerequisite checks it. | Provision and test archive creation and extraction. |
| medium | 174 | 1 | The only reviewer backend is Anthropic, so Claude workers cannot meet the promised different-family default. | Add another backend or define and test the same-family fallback. |
| low | 100 | 1 | Merge §0 says `herdr_master/` is repository-relative, but the package is under `herdr/orchestrator/herdr_master/`. | Make the path base explicit and consistent. |

## Root-cause groups

1. **The candidate has no single identity.** Staging, verification, secret scanning, model review,
   commit, and push can inspect different file sets.
2. **State has several competing authorities.** SQLite, TODO Markdown, `actions.jsonl`, and
   `units.jsonl` lack one crash-safe ownership and export model.
3. **The mandatory reviewer is not a complete state machine.** Its commands, payload limits,
   persistence, failure outcomes, billing, and next-attempt evidence are incomplete.
4. **The documented Herdr CLI is stale.** Session bootstrap and polling still call commands that
   the document's own probe rejected.
5. **Privilege boundaries accept agent-controlled inputs.** Git configuration, reviewer output,
   and alert bytes can cross into operator execution.
6. **New domain objects and services lack producers.** Initiative intake, daemon services, GitHub
   CLI, ntfy, Chrome profiles, mail security, SMTP, and archive support have no owned setup path.
7. **Usage controls compare or report incomplete units.** Provider percentages, token
   reservations, monetary caps, cache prices, and ambiguous billing do not form one closed model.
8. **Superseded rules remain normative.** Loop budgets, reset behavior, queue authority, and
   run-record shapes were extended without deleting or versioning the old contracts.

## Required ordering before implementation

1. Fix the three operator-execution paths: agent-owned Git configuration, reviewer-authored
   commands, and alert shell interpolation.
2. Bind OAuth approval to a trusted supervisor-initiated transaction.
3. Define one immutable candidate and run every gate against it.
4. Choose one state authority. Make TODO and JSONL files projections or exports.
5. Repair the verified CLI contract and produce a working session bootstrap.
6. Add initiative intake and decomposition before scheduler and viewer work.
7. Complete the reviewer, quota, billing, and schema-migration state machines.
8. Add the missing provisioning work.
9. Re-run all eight lenses on the revised source hash before code implementation resumes.
