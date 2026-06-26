---
name: review-changes
description: Review uncommitted git changes for bugs, security issues, and quality before committing
---

# Review Changes

Review all uncommitted changes in the current repository to ensure quality before committing.

## Process

1. **Show current state**:
   ```bash
   git status
   git diff --stat
   ```

2. **Review each changed file** by running `git diff <file>` and checking for:
   - **Bugs**: Logic errors, off-by-one, null checks
   - **Security**: Hardcoded secrets, SQL injection, XSS
   - **Quality**: Unused imports, dead code, obvious improvements
   - **Style**: Inconsistent formatting (auto-format should catch this)

3. **Provide summary** with:
   - List of files changed and why
   - Any issues found (categorized by severity)
   - Recommendations (commit as-is, fix issues first, split into multiple commits)

4. **Suggest commit message** based on the changes.

## Guidelines

- Focus on **correctness** over style (formatting hooks handle style)
- Flag security issues as **critical**
- Suggest splitting if changes touch unrelated concerns
- Be concise - don't explain obvious changes
