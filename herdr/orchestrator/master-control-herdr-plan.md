# Master Control Herdr Plan (Chief of Staff Architecture)

## 1. Executive Summary

Autonomous coding agents (Claude Code, Codex, Grok, Devin, etc.) operating across multiple machines frequently stall due to:
- **Interactive blocking prompts** (`[y/N]`, confirmation dialogs, license terms, diff approvals).
- **Ambiguous fork questions** ("Should I use X or Y?", "Where should I create this file?").
- **Premature completion declarations** (declaring a task complete without running or passing unit tests).
- **Environment disconnects** (network drops, machine-specific config divergence, terminal session death).

**Master Control Herdr** is a "Chief of Staff" supervisor layer built on top of [Herdr](https://herdr.dev). It monitors agent terminals across local and remote machines (via Tailscale/SSH), ingests their real-time state, automatically unblocks questions, enforces strict Definition-of-Done criteria through automated testing, and drives multi-step task queues to 100% completion.

---

## 2. System Architecture

```
                    ┌────────────────────────────────────────────────────────┐
                    │               MASTER CONTROL ORCHESTRATOR              │
                    │               (Chief of Staff Supervisor)              │
                    └───────────┬────────────────────────────────┬───────────┘
                                │                                │
            Tailscale / Local   │                                │  Tailscale / SSH
            Unix Domain Socket  ▼                                ▼
       ┌─────────────────────────────────┐              ┌─────────────────────────────────┐
       │     MACHINE A (Primary Mac)     │              │    MACHINE B (Remote Worker)    │
       │                                 │              │                                 │
       │  ┌───────────────────────────┐  │              │  ┌───────────────────────────┐  │
       │  │ MACHINE.md Context Pack   │  │              │  │ MACHINE.md Context Pack   │  │
       │  └─────────────┬─────────────┘  │              │  └─────────────┬─────────────┘  │
       │                │                │              │                │                │
       │  ┌─────────────▼─────────────┐  │              │  ┌─────────────▼─────────────┐  │
       │  │        Herdr Server       │  │              │  │        Herdr Server       │  │
       │  │  ┌─────────┐ ┌─────────┐  │  │              │  │  ┌─────────┐ ┌─────────┐  │  │
       │  │  │ Worker  │ │ Test/CI │  │  │              │  │  │ Worker  │ │ Test/CI │  │  │
       │  │  │ Pane 1  │ │ Pane 2  │  │  │              │  │  │ Pane 1  │ │ Pane 2  │  │  │
       │  │  └─────────┘ └─────────┘  │  │              │  │  └─────────┘ └─────────┘  │  │
       │  └───────────────────────────┘  │              │  └───────────────────────────┘  │
       └─────────────────────────────────┘              └─────────────────────────────────┘
```

### Core Components

1. **Machine Context Pack (`MACHINE.md`)**:
   - Resides on each target computer.
   - Defines local paths, ports, environment variables, installed tools, and architectural conventions.
   - Injected into agent sessions to preemptively answer 80% of environmental questions.

2. **Herdr Runtime Interface**:
   - Uses Herdr’s session persistence so agent processes survive disconnections and sleep modes.
   - Uses `herdr agent wait`, `herdr agent read`, `herdr agent prompt`, and `herdr agent send-keys` for non-invasive terminal telemetry and control.

3. **Autonomous Task Queue (`TODO.md`)**:
   - Checkbox-driven task specification on each machine.
   - Master Control dispatches one task at a time, preventing context exhaustion and ensuring single-purpose turns.

4. **Triage & Decision Engine**:
   - Classifies terminal output into:
     - **Trivial Confirmation**: `[y/N]`, `Press Enter`, license acceptance $\rightarrow$ Auto-send keys.
     - **Contextual Decision**: Directional fork $\rightarrow$ Evaluated against `MACHINE.md` / `SPEC.md` by a fast LLM.
     - **Dangerous Action**: `rm -rf`, database drop, credentials exposure $\rightarrow$ Escalate to human.
     - **Verification**: Agent claims completion $\rightarrow$ Trigger independent verification pane.

---

## 3. Operational Lifecycle (The OODA Loop)

```mermaid
flowchart TD
    Start([Start Task Run]) --> ReadTodo[Read Next Item in TODO.md]
    ReadTodo --> InjectPrompt[Inject Task + MACHINE.md Context via herdr agent prompt]
    InjectPrompt --> WaitState[Wait on herdr agent wait]
    
    WaitState -->|Status: blocked| CheckPrompt{Classify Prompt}
    CheckPrompt -->|Trivial y/n or Enter| SendKeys[herdr agent send-keys]
    CheckPrompt -->|Architectural Question| QueryLLM[Query Model with Context]
    CheckPrompt -->|Destructive / Dangerous| Escalate[Alert Human via Notification]
    SendKeys --> WaitState
    QueryLLM --> PromptResponse[herdr agent prompt with Answer]
    PromptResponse --> WaitState
    
    WaitState -->|Status: idle / done| TriggerTest[Run Independent Tests in Test Pane]
    TriggerTest --> TestPass{Tests Passed?}
    TestPass -->|No - Tests Failed| FeedErrors[Feed Test Trace Back into Agent]
    FeedErrors --> WaitState
    TestPass -->|Yes - All Green| Checkbox[Mark Task Done [x] in TODO.md]
    Checkbox --> MoreTasks{More Tasks in TODO?}
    MoreTasks -->|Yes| ReadTodo
    MoreTasks -->|No| Finish([All Tasks 100% Completed!])
```

---

## 4. Machine-Specific Context Specification (`MACHINE.md`)

Each machine hosts a localized configuration file that standardizes agent behavior for that specific device:

```markdown
# Machine Context & Autonomy Rules
- **Machine ID**: mac-mini-backend-01
- **Working Directory**: ~/projects/api-service
- **Runtime**: Node 22, Bun, Docker, Postgres (5432)
- **Rules**:
  1. Always use bun rather than npm or yarn.
  2. For database migrations, use `bun run db:migrate`.
  3. Never ask for confirmation before installing packages or creating directories.
  4. Never ask "Should I run tests?". Always run tests before declaring work done.
  5. Follow standard directory structure: routes in `src/routes`, logic in `src/services`.
```

---

## 5. Decision & Auto-Unblocking Strategy

When an agent enters the `blocked` state in Herdr, Master Control executes the following triage logic:

| Event Type | Detected Pattern | Automated Action |
|---|---|---|
| **Simple Confirmation** | `\[y/N\]`, `\(y/n\)`, `proceed\?` | `herdr agent send-keys <name> y enter` |
| **Pager / Continuation** | `Press Enter to continue`, `(END)`, `:` | `herdr agent send-keys <name> enter` or `q` |
| **Diff / Review Prompt** | `Accept this change\?`, `Approve diff\?` | `herdr agent send-keys <name> y enter` |
| **Architectural Fork** | *"Should I use library A or B?"* | Consult `MACHINE.md` + repo `README.md`; prompt decision via `herdr agent prompt` |
| **Safety Violation** | `rm -rf`, `DROP TABLE`, AWS key prompt | Pause runner, trigger system audio chime, send OS notification |
| **Infinite Loop** | Terminal buffer unchanged after 2 consecutive inputs | Halt agent, preserve session logs, ping human |

---

## 6. Definition-of-Done & Verification Engine

**Rule: Never trust the worker agent's self-assessment.**

1. When Herdr reports the agent is `idle` or `done`:
2. Master Control runs an independent verification command in a separate pane:
   ```bash
   herdr pane run <test-pane-id> "bun run lint && bun test"
   herdr pane wait-output <test-pane-id> --match "passed" --timeout 120000
   ```
3. If errors are found:
   - Output buffer is captured using `herdr pane read <test-pane-id> --source recent-unwrapped`.
   - The exact failure trace is fed back into the worker agent:
     `"Verification failed with code 1. Here is the error trace: [...] Fix these errors and ensure all tests pass."`
4. Only when exit code is `0` and all assertions pass is the task marked `[x]` in `TODO.md`.

---

## 7. Multi-Machine Fleet Management (Tailscale + SSH)

Herdr naturally supports distributed machines. Master Control coordinates the herd:

- **Saved Remote Profiles**:
  ```bash
  herdr machine add worker-studio --target user@studio.tailscale-net
  herdr machine add worker-linux --target dev@gpu-node.tailscale-net
  ```
- **Remote Execution Surface**:
  Commands run transparently over SSH without exposing raw unauthenticated sockets:
  ```bash
  ssh user@studio.tailscale-net "herdr agent wait worker-1 --until blocked"
  ssh user@studio.tailscale-net "herdr agent read worker-1 --source recent-unwrapped"
  ```
- **Central Dashboard**:
  A single master control process can cycle through all registered machines, checking each machine’s `TODO.md` and active agent status.

---

## 8. Autonomous Incident & Alert Ingestion (Email, Health Checks, SRE Fleet)

Master Control can act as an **Autonomous On-Call SRE Fleet**, ingesting incoming incident reports, health check alarms, and error emails, routing them directly to the appropriate computer and Herdr pane, and driving the remediation to verified resolution.

```
                      ┌─────────────────────────────────────────┐
                      │    Incoming Email / Alert Stream        │
                      │  (Sentry, Datadog, AWS, Health Checks)  │
                      └────────────────────┬────────────────────┘
                                           │
                                           ▼
                      ┌─────────────────────────────────────────┐
                      │        TRIAGE DISPATCHER AGENT          │
                      │  - Parses email body & stack traces     │
                      │  - Matches service to Machine & Pane    │
                      │  - Extracts error logs & reproduction   │
                      └────────────────────┬────────────────────┘
                                           │
                    Routing Decision       │ (Dispatches via Herdr)
           ┌───────────────────────────────┴───────────────────────────────┐
           │                                                               │
           ▼ (Tailscale SSH)                                               ▼ (Local Socket)
┌──────────────────────────────────────┐                       ┌──────────────────────────────────────┐
│       MACHINE A (Backend Node)       │                       │       MACHINE B (Frontend/Edge)      │
│                                      │                       │                                      │
│ Herdr Pane: `api-service`            │                       │ Herdr Pane: `web-client`             │
│ `herdr agent prompt api-service ...` │                       │ `herdr agent prompt web-client ...`  │
│                                      │                       │                                      │
│ Worker analyzes trace -> fixes code  │                       │ Worker fixes UI/bundle error         │
│ Runs `pytest` -> Confirms 200 OK     │                       │ Runs `npm test` -> Confirms build    │
└──────────────────┬───────────────────┘                       └──────────────────┬───────────────────┘
                   │                                                              │
                   └───────────────────────────────┬──────────────────────────────┘
                                                   ▼
                                  ┌─────────────────────────────────┐
                                  │      RESOLUTION FEEDBACK        │
                                  │  - Creates PR: `fix/alert-4091` │
                                  │  - Replies to email thread with │
                                  │    diff & health check proof    │
                                  └─────────────────────────────────┘
```

### Inbound Ingestion Pipeline
1. **Email / Alert Ingestion**:
   - Monitored via a dedicated lightweight IMAP poller (`alert_poller.py`) or inbound webhook receiver.
   - Ingests alerts from Sentry, Datadog, AWS CloudWatch, Pingdom, and uptime monitors.
2. **Alert De-duplication & Throttling**:
   - Groups repeating alarm bursts into a single incident ID.
   - Prevents cascading tasks from flooding agent panes.

### Service Routing Matrix (`ROUTER.json`)
The Dispatcher maps incoming service names and stack traces to physical machines and Herdr panes:

```json
{
  "services": {
    "auth-api": {
      "machine": "local",
      "herdr_pane": "api-worker",
      "repo_path": "/Users/joggerjoel/projects/auth-api",
      "health_check_url": "http://localhost:8080/health",
      "verification_cmd": "pytest tests/test_auth.py"
    },
    "billing-service": {
      "machine": "mac-studio.tailnet",
      "herdr_pane": "billing-worker",
      "repo_path": "/Users/dev/projects/billing",
      "health_check_url": "http://100.x.y.z:9000/health",
      "verification_cmd": "cargo test"
    }
  }
}
```

### Dynamic Dispatching & Concurrency Handling
- **If target pane is `idle`**: Master Control immediately prompts the pane with the incident stack trace and reproduction steps.
- **If target pane is `working`**: Master Control uses Herdr's git worktree isolation to spin up an isolated sibling pane:
  ```bash
  herdr pane split --current --direction right --no-focus
  herdr agent start incident-worker --kind claude --pane <new-pane-id>
  ```

### Resolution Feedback Loop
1. Worker writes fix and regression test.
2. Verification pane runs test suite and executes a live HTTP curl against the health check endpoint.
3. Master Control auto-commits to a `fix/incident-<id>` branch and opens a PR.
4. Auto-replies to the original email thread with the commit diff, passing test log, and resolution summary.

---

---

## 9. Zero-Touch Subscription Auto-Auth & Rate-Limit Management (Browser & OTP Bridge)

To eliminate the cost volatility and runaway risks of metered API keys, Master Control is designed to operate on **flat-rate monthly subscriptions** ($20/mo plans like Claude Pro/Team or ChatGPT Plus). It automates the two primary friction points of subscription plans: **expiring browser sessions** and **hourly rate limits**.

```
┌────────────────────────────────────────────────────────────────────────┐
│  1. TERMINAL SESSION EXPIRES (In Herdr Pane)                           │
│     Agent CLI prints:                                                  │
│     "Session expired. Authorize at: https://claude.ai/activate?c=XYZ9" │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼ Herdr reads buffer
┌────────────────────────────────────────────────────────────────────────┐
│  2. MASTER CONTROL DETECTS AUTH URL & CODE                             │
│     herdr_unblocker catches regex:                                     │
│     URL: https://.../activate  |  Code: XYZ9-4210                       │
└──────────────────┬─────────────────────────────────┬───────────────────┘
                   │                                 │
                   ▼ (Standard Device Flow)          ▼ (If Email OTP Sent)
┌───────────────────────────────────────┐ ┌──────────────────────────────┐
│  3. CHROME BACKGROUND AUTO-APPROVAL   │ │  4. EMAIL OTP AUTO-HARVEST   │
│  - Opens URL in background Chrome tab │ │  - IMAP listener grabs code  │
│  - Uses your existing active cookies  │ │    from inbox in < 3 seconds │
│  - Auto-clicks "Approve / Authorize"  │ │  - Injects OTP into prompt   │
└──────────────────┬────────────────────┘ └──────────────┬───────────────┘
                   │                                     │
                   └──────────────────┬──────────────────┘
                                      ▼ Handshake completes
┌────────────────────────────────────────────────────────────────────────┐
│  5. TERMINAL UNBLOCKS & RESUMES WORK                                   │
│     CLI receives fresh token and continues the TODO list sprint!       │
└────────────────────────────────────────────────────────────────────────┘
```

### 1. The Economics: Flat Subscription vs. Metered API Keys
- **Metered API Keys**: Have no financial ceiling. An agent caught in an automated loop can burn through $50–$500 in hours.
- **Flat-Rate Subscriptions ($20/mo)**: Guarantee a predictable hard spending ceiling with high volume, but require periodic re-authentication and enforce hourly rate limits.

### 2. Automated Browser Authorization Bridge (`herdr_auth_bridge.py`)
1. **Detection**:
   - `herdr_unblocker` monitors for OAuth/device authorization patterns:
     ```python
     AUTH_URL_REGEX = r"https?://(?:claude\.ai|x\.ai|github\.com)/[a-zA-Z0-9_\-/?=&]+"
     DEVICE_CODE_REGEX = r"(?:code|code is):\s*([A-Z0-9]{4,8}-[A-Z0-9]{4,8})"
     ```
2. **Chrome Background Auto-Approval**:
   - Master Control calls a lightweight macOS AppleScript or local Chrome extension.
   - Chrome opens the activation link in a background tab using your already-authenticated profile (no passwords stored in plaintext).
   - The script clicks the `[Approve / Authorize]` button and closes the tab.
3. **Email OTP Auto-Harvesting**:
   - If an email verification code is dispatched, the IMAP listener (from Section 8) parses the 6-digit code from the inbox and automatically injects it into the terminal or browser prompt.

### 3. Rate-Limit Graceful Sleep & Auto-Resume
When an agent reaches its hourly or daily subscription limit:
1. Herdr intercepts the notice: `"You've reached your limit until 2:45 PM"`.
2. Master Control parses the timestamp, logs the sleep state, and sets a countdown timer.
3. At exactly 2:45:05 PM, Master Control sends:
   ```bash
   herdr agent prompt <worker> "Your limit has reset. Please resume the previous task from TODO.md."
   ```
4. Work continues seamlessly without manual intervention or wasted downtime.

---

## 10. Failure Modes & Safety Guardrails

1. **Consecutive Loop Detection**:
   - Tracks hash of last 3 terminal buffers.
   - If buffer hash matches consecutively, unblocker disengages to prevent burning API tokens on a loop.
2. **Context Blowout Mitigation**:
   - If an agent turn count exceeds 25 turns or token limit is reached, Master Control commits progress to a checkpoint branch, resets the agent session, and passes a clean summary to a fresh agent.
3. **Emergency Stop**:
   - Global abort command: `herdr-ctl abort --all` sends `ctrl+c` to all active panes and halts supervisors.


