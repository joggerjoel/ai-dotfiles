Run the two-model fusion harness in FUSE mode on this prompt: $ARGUMENTS

Execute exactly:
bash "$HOME/.claude/skills/fusion/scripts/fusion.sh" fuse '<the prompt above, single-quoted safely>'

(If the arguments contain two quoted strings, pass the second as the custom merge
instruction argument.)

ARCHITECT (claude) and BUILDER (codex) answer independently in parallel, then a FUSION
agent merges them with [ARCHITECT]/[BUILDER]/[BOTH] attribution and a
"## Fused Result / ## Consensus / ## Divergence / ## Discarded" structure. The script
prints the fused result and the run directory.

Then: relay the fused result verbatim, summarize consensus vs divergence in one or two
sentences, and point at <run-dir>/report.html for the visual convergence cards. Do not
merge or re-answer yourself — the harness's fusion agent owns the merge.
