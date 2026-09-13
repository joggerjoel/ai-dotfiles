# Capability-grid council resolution

Date: 2026-09-13. Status: design and roadmap revised; implementation acceptance remains open.

The eight-lens review compared the capability grid with the merge plan and TODO. Its combined
source SHA-256 was `074812614dba4d872b4e42fdc25b36cf9a2f60a93b155b9124a2e118c2656bcd`.
The review produced 30 raw findings, merged into 22 anchored entries across 15 root causes.
The reviewers used one model, so this was not independent multi-provider consensus.

This file records disposition, not a second design authority. The
[merge plan](merge-busybrain-herdr-plan.md) defines the contracts; the
[merge TODO](merge-busybrain-herdr-todo.md) defines implementation and acceptance work.
Historical council reports describe their audited source versions and are not rewritten as
though they reviewed this revision. No unchecked implementation item becomes complete here.

## Finding disposition

All 22 anchored entries are accepted as design work. Related anchors share the implementation
tasks below; severity labels from the audit do not claim a demonstrated runtime exploit.

| Finding ID | Plan contract | Implementation and acceptance tasks |
| --- | --- | --- |
| `rt-review-command-authority` | §2.2 typed checks, no model shell | C.2, C.5, C.9 |
| `arch-e2e-placement-without-runner` | §2.12 real-app gate | L.1-L.7 |
| `arch-requirement-ledger-has-no-producer` | §2.11 requirement producer | K.1-K.3, K.6 |
| `da-initiative-producer-unscheduled` | §2.11 intake and acceptance mapping | K.1-K.3, K.6 |
| `arch-runrecord-authority-conflicts` | §2.6 canonical SQLite and replayable export | F.1-F.5 |
| `da-browser-rest-gates-unscheduled` | §2.12 service, REST, browser contracts | L.2-L.4, L.7 |
| `arch-review-input-is-not-candidate-bound` | §2.2 immutable review identity | C.4, C.9 |
| `cm-reservation-unit-cannot-be-compared-to-window` | §2.8 units and enforced bounds | H.1-H.3, H.8-H.9 |
| `rt-unconfirmed-blocker-bypass` | §2.2 tri-state confirmation/recovery | C.5, C.7, C.9 |
| `cm-cli-calls-have-no-admission-boundary` | §2.8 supported worker modes | H.3, H.9 |
| `rt-review-candidate-swap` | §2.2 verdict invalidation at landing | C.4, C.9 |
| `cm-provider-snapshot-reconciliation-is-undefined` | §2.8 snapshot coverage and reset identity | H.8, H.10 |
| `prov-browser-runtime-acquisition` | §2.12 pinned and probed browser runtime | L.5, L.7 |
| `rt-cli-bypasses-call-reservation` | §2.8 mediated child/CLI calls | H.9 |
| `rel-offline-source-recovery-gap` | §2.9 acknowledged checkpoints and loss policy | I.10 |
| `sec-review-outbound-secret-gate` | §2.2 full-payload pre-send screening | C.1, C.9 |
| `cq-unstable-finding-fingerprints` | §2.5 canonical checked failure identity | E.1-E.3 |
| `arch-registered-actor-lifecycle-missing` | §2.7 actor registration and budget ownership | G.9, J.5 |
| `prov-price-schedule-producer` | §2.10 price source/version/coverage | J.13 |
| `cm-cached-token-cost-semantics-undefined` | §2.10 disjoint billing categories | J.7-J.8, J.13 |
| `cq-unbounded-accumulated-review-diff` | §2.2 bounded unit delta, no silent truncation | C.10 |
| `rel-existing-state-migration-omitted` | §2.7 versioned migration and legacy recovery | G.1, G.7 |

## Additional synthesis corrections

- Human-blocked requirements prevent successful completion. Administrative closure is separate.
  Explicit operator waivers retain identity, reason, and revision. K.3 and K.6 prove this rule.
- K.4 defines the legacy queue import boundary and generated Markdown authority. Old prose and
  agent-written check marks cannot override verified state.
- G.2 covers uncertain external effects, not just database compare-and-swap. G.10 supplies daemon
  service provisioning. G.11 tests the reported unblocker response mismatch before changing code.
- J.12 defines snapshot revisions and replay; J.10 covers evidence downloads and remote access.
- Phase numbers are integration references, not an order that puts quota work after its consumers.
  The local release precedes fleet execution and the viewer.

## Deliberate limits

Deployment control, live process migration, and mandatory visual regression remain out of scope.
No BusyBrain executable modules are imported. Unsupported CLI modes cannot claim strict quota
admission. Percentage-only subscription telemetry cannot prove projected token reservation, and
unknown per-call cost remains unavailable. These are explicit limits, not completed capabilities.

The BusyBrain watchdog shutdown remains a separate operator action. This documentation change
does not stop services, alter credentials, merge pull requests, or deploy anything.

## Verification results

| Check | Status | Details |
| --- | --- | --- |
| Typecheck | Not applicable | Only Markdown changed. |
| Document validation | Pass | Twelve plan sections/pieces, 90 unique unchecked tasks, 22 dispositions, valid task references and fences. |
| Diff and credential-pattern checks | Pass | No whitespace errors or credential-pattern matches in the changed documents. |
| Herdr tests | Pass | 112 supervisor tests and 8 unblocker tests. |
| Repository suites | Fail | 381 passed; one fleet inventory assertion and three observability assertions failed in unchanged code/configuration. |
| Build | Not applicable | No executable source or build inputs changed. |

Recommendation: commit the scoped documentation revision with the repository-suite caveat.
The full repository is not green. The failures concern fleet fallback inventory, rendered scrape
targets, missing exporter groups, and observability placement; they are not resolved by this change.
