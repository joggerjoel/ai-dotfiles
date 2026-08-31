---
description: Add, commit, push, and merge the current branch into main
argument-hint: "[optional commit message; omitted = written from the diff]"
---

Ship the working tree: stage everything, commit, push, and land it on `main`.

Commit message: $ARGUMENTS

## Steps

1. `git status --short` and `git diff` (plus `git diff --cached`) to see what is
   actually being shipped. If the tree is clean and nothing is staged, say so and stop.
2. Write the commit message **from the diff** if none was given above. Match the
   repository's existing style — read `git log -5` first. Never add AI attribution,
   "Generated with" footers, or Co-Authored-By lines.
3. `git add -A`, then **inspect what got staged before committing**. If anything looks
   like a credential — `creds.json`, `.env*`, `*.pem`, `*_rsa`, an `auth/` directory,
   a token or key file — STOP, unstage it, add it to `.gitignore`, and tell the user.
   Never commit it "just this once". Then commit.
4. Push the current branch to `origin`.
5. **If the current branch is not `main`:** check out `main`, `git pull --ff-only
   origin main`, `git merge --no-ff <branch>`, push `main`, then return to the original
   branch. If the merge conflicts, stop and report the conflicting files — never
   resolve a conflict unasked.
6. **If already on `main`:** the commit and push in step 3-4 are the whole job. Do not
   create a branch, and do not merge.

## Rules

- Report what actually happened: the SHA, the branch, whether a merge ran.
- If tests exist and are quick, run them before committing and report failures rather
  than shipping over them.
- Never force-push.
