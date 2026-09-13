# Build guide

This guide is a reading and execution guide, not another architecture specification.
The [master plan](../master-control-herdr-plan.md) is the baseline. Explicit amendments in the
[merge plan](../merge-busybrain-herdr-plan.md) take precedence where they identify the changed rule.

## Before implementing a unit

1. Select an unchecked task in the [master TODO](../master-control-herdr-todo.md) or
   [merge TODO](../merge-busybrain-herdr-todo.md). Read its governing plan section and prerequisites.
2. Check the [review inventory](../inventory/reviews/README.md) for relevant unresolved findings.
   The broader audit has no complete current disposition. Do not assume the merge council closed it.
3. Write acceptance checks and identify the candidate, policy, and evidence the supervisor must own.
4. Apply merge plan §2.13's proportional design gate. Reuse existing interfaces where suitable;
   explain any new boundary or abstraction and the simpler alternative considered.
5. Implement only the unit's scope, run its checks, and review the actual diff. Record incomplete
   evidence honestly; a passing function test is not a live provider or fleet test.

## Delivery order

Follow merge plan §4 rather than sorting phase numbers. Build the local queue-to-attempt lifecycle,
durable close/recovery, supported quota admission, intake, and candidate-bound verification first.
Then extend placement to multiple machines. Build status from the same records before the viewer.
Introduce §2.13's design records with planning and its architecture gate before integration.

The daemon, planner, reviewer, service lifecycle, fleet scheduler, and design gate remain roadmap
work until their acceptance checks pass. Do not report the whole orchestrator as operational from
the existing unit-test count.

## Verification commands

From the repository root, run the relevant checks separately and stop to investigate a failure:

```sh
python3 -m unittest discover -s herdr/orchestrator/herdr_master -p 'test_*.py'
python3 -m unittest discover -s herdr/orchestrator -p 'test_unblocker.py'
python3 -m unittest discover -s skills/amnesiac-workers/scripts -p 'test_*.py'
bash -n herdr/orchestrator/attempt_prototype.sh
git diff --check
bash scripts/run-all-tests.sh
```

The 2026-09-13 check passed 155 scoped tests. The repository-wide suite reported 381 passes and
four fleet/observability failures. Those are dated observations, not a waiver or a permanent
baseline. Recheck affected dependencies and report current failures before shipping a change.

Live gates need approved throwaway repositories, services, credentials, and machines. Reading
this guide does not authorize deployments, service shutdown, credential changes, or auto-merging PRs.

## Maintaining the documents

Change the governing plan first, then linked TODO tasks and acceptance tests. Keep review reports
as dated evidence with their original findings. Record accepted, rejected, deferred, and superseded
dispositions separately. Add links here or in the inventory rather than creating competing plans.
Do not copy the full archive into every worker prompt. Packets include only applicable approved
requirements, design constraints, failure evidence, and references.
