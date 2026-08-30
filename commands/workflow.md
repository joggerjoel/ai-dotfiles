---
description: Route a task through the skills playbook and run it end to end
argument-hint: "[what you want done, in plain language]"
---

Invoke the `workflow` skill (via the Skill tool) to route this task through the
six-phase skills playbook and carry it out.

Task: $ARGUMENTS

If no task was provided above, ask what should be built or fixed before
proceeding. Then follow the workflow skill's instructions exactly — resolve the
policy, print the route-and-chain block before doing any work, and run the chain
through to the end.
