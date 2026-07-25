---
description: Run the SHIPIT cold-review loop on document(s) — isolate --wide, write back MATERIAL findings, loop --review to MATERIAL 0
---

# /isolate <file> [file...]

You are running the SHIPIT convergence loop (see SHIPIT.md) on the document(s) in
"$ARGUMENTS". The cold passes come from the `isolate` CLI (clean-room, zero-context);
you are the context-loaded author who writes findings back.

## Loop

1. **Find pass**: run via Bash — `isolate --wide "$(cat <files>)"` (one deep fable
   pass + 4 sonnet lenses, parallel; takes a few minutes — use a generous timeout or
   background it).
2. **Triage**: collect every finding labeled MATERIAL across all five sections;
   dedupe (the lenses overlap on purpose — the same defect from two lenses is one
   finding, with higher confidence). Ignore the counts arithmetic; trust labels.
   Discard findings that misread the doc — but say so explicitly, with the quote
   that refutes them.
3. **Write back**: apply every surviving MATERIAL finding to the document(s) —
   criticals first. NITs: apply only the free ones (typos, stale names); skip
   style churn.
4. **Converge**: run `isolate --review "$(cat <files>)"` (one deep pass, rubric).
   If any MATERIAL remains → write back → repeat this step. `MATERIAL: 0` from the
   deep model = converged. (A cheap model's silence never counts as convergence.)
5. **Report**: rounds used, findings fixed per round (one line each), findings
   rejected with reasons, and the final MATERIAL: 0 line. If the docs live in a
   git repo, offer to commit the write-backs (do not commit unasked).

## Rules

- Never edit the documents to _satisfy the reviewer's phrasing_ — fix the defect.
- If a finding contradicts a deliberate, documented decision, do not "fix" it —
  cite the decision in the report and, if the doc was unclear enough to mislead a
  cold reader, clarify the decision's wording instead.
- 5 rounds without convergence = stop and tell the user something structural is
  wrong (the SHIPIT runaway cap).
