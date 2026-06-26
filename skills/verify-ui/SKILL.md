---
name: verify-ui
description: Browser-based UI verification using agent-browser with Chrome fallback
disable-model-invocation: true
allowed-tools: Bash(agent-browser:*), Bash(bun run dev*)
---

# Verify UI

Test UI changes by actually using the application in a browser. This catches issues that automated tests miss.

## Process

### 1. Start Dev Server (if not running)
```bash
# Detect and start appropriate dev server
bun run dev &
# Wait for server to be ready
sleep 3
```

### 2. Primary: agent-browser (Fast, Headless)

Use agent-browser for quick verification:

```bash
# Navigate to the app
agent-browser navigate http://localhost:3000

# Take a screenshot of the current state
agent-browser screenshot

# Test key interactions
agent-browser click "button:Login"
agent-browser fill "input[name=email]" "test@example.com"

# Get page content/structure
agent-browser snapshot
```

**Best for**: Quick headless testing, CI/CD, no authentication required

### 3. Fallback: Chrome Integration

If agent-browser encounters issues (login required, CAPTCHA, complex auth):

> Switch to Chrome mode: Run `claude --chrome` in a new terminal, then use `/chrome` to verify connection.

**Chrome Integration provides**:
- Real browser with your login sessions
- All chrome-devtools MCP tools
- Console log access and debugging
- Network request inspection
- GIF recording of interactions

**Best for**: Authenticated apps, debugging, apps requiring real login state

## Verification Checklist

For each UI change, verify:

- [ ] **Visual**: Does it look correct? (Take screenshots)
- [ ] **Interactive**: Do buttons/links work?
- [ ] **Responsive**: Check different viewport sizes
- [ ] **States**: Test loading, error, empty states
- [ ] **Accessibility**: Can you navigate with keyboard?

## Guidelines

- Start with agent-browser (faster, no setup)
- Switch to Chrome Integration if:
  - Login is required
  - CAPTCHA appears
  - Complex OAuth flow needed
  - Need to debug with DevTools
- Take screenshots at each step for documentation
- Iterate until the UX feels right, not just "works"
