Run the two-model fusion harness in OPINION mode on this prompt: $ARGUMENTS

Execute exactly:
bash "$HOME/.claude/skills/fusion/scripts/fusion.sh" opinion '<the prompt above, single-quoted safely>'

This fans out ARCHITECT (claude -p) and BUILDER (codex exec) in parallel; both answer
independently with no file writes. When it finishes it prints the run directory.

Then: read <run-dir>/architect.txt and <run-dir>/builder.txt and present both answers
side by side with the stat line (wall secs per agent from the script output). Mention
that <run-dir>/report.html has the visual side-by-side comparison. Do not re-answer
the prompt yourself — your job is to run the harness and relay both perspectives.
