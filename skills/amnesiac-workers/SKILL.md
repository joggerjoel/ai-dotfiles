---
name: amnesiac-workers
description: "Run an autonomous fix-verify loop where the worker's conversation is destroyed after every attempt and only typed, evidence-bearing state survives. Use when designing or debugging a retry loop that feeds failures back into the same agent, when attempt N inherits attempt N-1's reasoning, or for 'context contamination', 'fresh worker per attempt', 'should the agent resume or restart', 'handoff summary between attempts'."
---

# Amnesiac workers

Master has memory. Workers have amnesia. The repository has truth. Tests determine completion.

Apply to any loop that retries a task after a verifier fails. The default shape of such a loop
feeds the failure back into the agent that produced it, so attempt 10 carries nine attempts of
reasoning, discarded hypotheses, and tool chatter. That context is not neutral. A wrong theory
stated in attempt 2 is still sitting in the window at attempt 9, and the model reads its own
prior output as evidence.

Destroying the worker after every attempt is not a mitigation for context exhaustion. It is the
normal operating mode.

## The four invariants

**Workers are destroyed per attempt, not per blowout.** A worker is dispatched, edits the repo,
exits. Its conversation ends there. There is no resume path, so there is no reset budget and no
threshold to tune.

**The repository is the medium of progress.** Each attempt commits its work, which makes the diff
the handoff. Files changed and current commit are read from git at packet-build time, never
stored, because a stored copy drifts from git the moment an attempt dies between the commit and
the write.

**Surviving state carries evidence, never reasoning.** A record names the command that produced
it and quotes that command's output. This is enforced by a closed schema, not by instruction, so
"I think the auth layer is wrong" has no field to live in. See `references/task-packet.md`.

**Only the verifier closes a task.** The worker's completion claim is a trigger to run the
verifier, never proof. This is the one invariant most loops already have.

## The loop

```
1. Run the verifier.
2. Pass  -> independent review -> done.
3. Fail  -> build a fresh packet: goal, remaining TODO, repo instructions,
            current code, the verifier failure, validated facts and blockers.
4. Dispatch a clean worker with that packet and nothing else.
5. Worker edits the repo and exits.
6. Commit the attempt. Write the typed master state.
7. Destroy the worker context.
8. Go to 1.
```

Step 6 before step 7 is load-bearing. Destroying a worker whose work was never committed loses
the attempt entirely, and the next worker then repeats it against an unchanged tree.

Build the packet in step 3 from scratch every time. Mutating the previous packet reintroduces
accumulation through the back door.

Include the blocker instruction in every packet, not just when a task looks risky. A worker with
no way to report an unreachable goal reports success instead, and the loop spends its whole retry
budget rediscovering the same wall. `references/task-packet.md` gives the wording that worked.

## What the master persists

Four fields and one nested verification result, listed in `references/task-packet.md`. Everything
else derives from git and the queue. The schema rejects derived fields outright rather than
tolerating a stale duplicate.

The worker writes discoveries to `facts.json` and `blockers.json` in the work tree. Treat both as
untrusted input from a process that just failed. Validate at the boundary before promoting any
record into the next packet:

```bash
python3 scripts/validate_state.py .herdr/facts.json
```

A file that fails validation is dropped whole and its reasons escalated. Salvaging half of a
contaminated ledger is the judgment call this design exists to remove.

Do not place master state inside the work tree. A worker that can edit its own attempt counter,
retry budget, or verifier record can talk itself into a pass.

## What does not survive

Prose handoffs, structured or not. A handoff that reports "what remains and the next step" is
carrying a hypothesis forward under a different name, and a wrong one propagates further than it
would have in a raw transcript because it arrives stripped of the uncertainty that produced it.

If a loop currently elicits a handoff before restarting an agent, delete that step rather than
constraining its wording. The evidence fields in `facts.json` already carry everything a handoff
legitimately carried.

## Budgets

One counter, the retry budget, decremented on verifier failure. Context resets no longer exist as
a distinct event, so a separate reset budget has nothing to count.

Cap injections per attempt rather than per task. Unblocking prompts, auth handshakes, and
confirmations still accrue inside a single attempt, and a worker that burns its cap without
reaching the verifier is stuck. Escalate that worker instead of nudging it further.

## Rotating models

The packet names no author, so nothing in it needs translation between models. Attempt 3 can run
on a different model than attempt 2, and a final review can run on a third. Vary the model when
attempts fail for different reasons each time; keep it fixed when they fail identically, since
that signals an underspecified goal rather than a model limitation.

## Where this is wrong

This design trades tokens for independence. A task whose difficulty lives in accumulated
understanding of a large unfamiliar codebase pays real rediscovery cost on every attempt, and
`facts.json` recovers only the part that reduces to evidence. Prefer a single long-lived worker
when attempts are cheap, few, and exploratory. Prefer amnesia when a verifier is authoritative
and attempts exceed roughly three.

## Additional resources

- **`references/task-packet.md`** - Packet contents, the three schemas, worked examples, limits.
- **`scripts/validate_state.py`** - Boundary validator. Exit 0 valid, 1 invalid, 2 unreadable.
- **`scripts/test_validate_state.py`** - `python3 -m unittest test_validate_state` from `scripts/`.

An implementation of these invariants, with the pane, worktree, and escalation machinery a real
fleet needs, is specified in the sibling project's
[master-control plan](../../../herdr-orchestrator/master-control-herdr-plan.md), sections 6 and 10.2.
