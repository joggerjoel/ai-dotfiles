---
name: verify
description: Full verification loop - typecheck, test, lint, build. Use before committing or merging.
---

# Verify

Run comprehensive verification to ensure code quality before committing or merging.

## Process

Run these checks in order, stopping on first failure:

### 1. Type Check
```bash
# TypeScript
bunx tsc --noEmit

# Python (if using type hints)
uv run mypy .

# Go
go build ./...
```

### 2. Lint
```bash
# TypeScript/JavaScript
bunx eslint . --max-warnings 0

# Python
uv run ruff check .

# Go
golangci-lint run
```

### 3. Test Suite
```bash
# Bun
bun test

# Vitest
bunx vitest run

# Jest
bunx jest

# Python
uv run pytest

# Go
go test ./...
```

### 4. Build (if applicable)
```bash
# Next.js / Vite / etc
bun run build
```

## Output

Report results in this format:

```
## Verification Results

| Check | Status | Details |
|-------|--------|---------|
| TypeCheck | PASS/FAIL | 0 errors |
| Lint | PASS/FAIL | 2 warnings |
| Tests | PASS/FAIL | 45 passed, 0 failed |
| Build | PASS/FAIL | Built in 12s |

### Issues Found
- [List any issues that need attention]

### Recommendation
[READY TO COMMIT / FIX ISSUES FIRST / NEEDS REVIEW]
```

## Guidelines

- Stop on first **error** (not warnings) to avoid cascading failures
- Detect the project type automatically from config files
- Skip checks that don't apply (e.g., no lint config = skip lint)
- Be clear about what failed and why
