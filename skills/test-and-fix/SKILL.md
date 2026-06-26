---
name: test-and-fix
description: Run tests, analyze failures, and automatically fix them
disable-model-invocation: true
---

# Test and Fix

Run the project's test suite, analyze any failures, and automatically fix them.

## Process

1. **Detect test framework** by checking for:
   - `bun test` (check for `bun.lockb` or test files with Bun imports)
   - `vitest` (check for `vitest.config.*`)
   - `jest` (check for `jest.config.*` or jest in package.json)
   - `pytest` (check for `pytest.ini`, `pyproject.toml` with pytest)
   - `go test` (check for `*_test.go` files)

2. **Run tests** using the detected framework:
   ```bash
   bun test           # Bun projects
   bunx vitest run    # Vitest
   bunx jest          # Jest
   uv run pytest      # Python
   go test ./...      # Go
   ```

3. **Analyze failures** by:
   - Reading the error messages and stack traces
   - Identifying which files and functions failed
   - Understanding the root cause (assertion failure, runtime error, etc.)

4. **Fix issues** by:
   - Reading the failing test file
   - Reading the implementation file being tested
   - Making the minimal change to fix the failure
   - Re-running tests to verify the fix

5. **Iterate** until all tests pass or you identify a deeper issue requiring human input.

## Guidelines

- Fix the **implementation**, not the test (unless the test is clearly wrong)
- Make **minimal changes** - don't refactor while fixing
- If a test seems fundamentally wrong, ask before modifying it
- If you can't fix after 3 attempts, explain the issue and ask for help
