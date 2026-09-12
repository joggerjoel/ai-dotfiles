# Master Control Herdr Execution Roadmap (TODO)

This checklist tracks the implementation of the Master Control (Chief of Staff) system for autonomous, multi-machine agent execution via Herdr.

---

## Phase 1: Local Herdr Baseline & Machine Context Setup
- [x] **1.1 Verify Local Herdr Installation & Server Health**
  - [x] Confirm `herdr status` reports valid client and server status.
  - [x] Verify `herdr agent` and `herdr integration` CLI capabilities.
- [x] **1.2 Create Local Machine Context Pack (`MACHINE.md`) Template**
  - [x] Document local OS, architecture, installed runtimes (Python/Node/Go/Rust), and preferred package managers.
  - [x] Define local ports, database conventions, and environment paths.
  - [x] Codify core autonomy guidelines ("Never ask permission to run tests or install dependencies").
- [x] **1.3 Create Project-Level `TODO.md` Standard Schema**
  - [x] Establish standard checkbox formatting (`- [ ] Task Description`).
  - [x] Standardize task acceptance criteria format per task item.

---

## Phase 2: Core Auto-Unblocker & Prompt Interceptor
- [x] **2.1 Build State Detector Service**
  - [x] Hook into `herdr agent wait <agent> --until blocked` to capture blocked lifecycle events.
  - [x] Implement clean terminal buffer capture via `herdr agent read <name> --source recent-unwrapped`.
  - [x] Implement fallback to `--source visible` for alternate-screen/TUI applications.
- [x] **2.2 Implement Pattern Matching Engine for Trivial Questions**
  - [x] Auto-confirm `[y/N]` and `(y/n)` interactive prompts (`herdr agent send-keys <name> y enter`).
  - [x] Auto-clear `Press Enter to continue` / pager halts (`herdr agent send-keys <name> enter`).
  - [x] Auto-approve routine file diff reviews and tool authorizations.
- [x] **2.3 Implement Anti-Loop & Backoff Circuit Breaker**
  - [x] Hash recent terminal buffers to detect duplicate consecutive prompts.
  - [x] If blocked state repeats $\ge 3$ times with identical buffer, freeze agent and alert.
- [x] **2.4 Implement Model-Assisted Triage for Ambiguous Questions**
  - [x] Structure extensible classification pipeline for LLM dispatch.
  - [x] Ensure safety gate escalation for dangerous commands (`rm -rf`, `DROP TABLE`).

---

## Phase 3: Autonomous Task Queue Dispatcher (`TODO.md` Runner)
- [ ] **3.1 Build Task Parser & State Machine**
  - [ ] Read local `TODO.md`, locate the first unchecked item (`- [ ]`), and mark it as in-progress.
  - [ ] Format prompt combining `MACHINE.md` rules + specific task description.
  - [ ] Dispatch task to the dedicated Herdr agent pane.
- [ ] **3.2 Monitor Turn Execution to Completion**
  - [ ] Wait for agent status to transition to `idle` or `done`.
  - [ ] Handle mid-turn questions via the Phase 2 Auto-Unblocker.
  - [ ] Automatically mark task as completed (`- [x]`) upon successful verification.
  - [ ] Loop immediately to the next item until all checkboxes are marked.

---

## Phase 4: Independent Verification Gate (Definition of Done)
- [ ] **4.1 Create Dedicated Verification Pane in Herdr**
  - [ ] Split sibling pane without stealing focus (`herdr pane split --current --direction right --no-focus`).
- [ ] **4.2 Automated Test & Build Assertion**
  - [ ] Run project test suite (`npm test`, `pytest`, `cargo test`, `just test`) inside verification pane.
  - [ ] Await exit code and scan output for assertion failures or compilation errors.
- [ ] **4.3 Automated Error Remediation Loop**
  - [ ] If tests fail, extract error trace with `herdr pane read <pane-id> --source recent-unwrapped`.
  - [ ] Re-prompt the worker agent with the failure output.
  - [ ] Require tests to pass 100% green before updating `TODO.md`.

---

## Phase 5: Multi-Machine Herd & Remote Execution (Tailscale + SSH)
- [ ] **5.1 Machine Inventory & Tailscale Registration**
  - [ ] Configure `herdr machine add` profiles for each remote Mac and Linux workstation.
  - [ ] Verify passwordless SSH authentication across Tailscale network.
- [ ] **5.2 Remote State Synchronization**
  - [ ] Enable remote inspection (`ssh <node> "herdr agent get <agent> --json"`).
  - [ ] Enable remote input dispatch (`ssh <node> "herdr agent prompt <agent> '...'"`).
- [ ] **5.3 Machine-Specific Task Routing**
  - [ ] Allow Master Control to dispatch machine-appropriate tasks (e.g. GPU jobs to Linux, UI/macOS jobs to Mac).

---

## Phase 6: Human Escalation & Notification Channels
- [ ] **6.1 Desktop Notifications**
  - [ ] Trigger macOS notification (`osascript`) when a task requires human intervention.
  - [ ] Play distinct audio chime on critical block or completion.
- [ ] **6.2 Remote Alerts (Optional Webhook)**
  - [ ] Send webhook notification (Telegram, Discord, Slack, or Pushover) when an entire `TODO.md` sprint finishes.
- [ ] **6.3 Master Dashboard / Status TUI**
  - [ ] Display live status of all running agents across all machines in a unified view.

---

## Phase 7: Autonomous Incident & Email Alert Ingestion (On-Call SRE Engine)
- [ ] **7.1 Inbound Email & Alert Listener**
  - [ ] Implement IMAP listener / webhook intake service (`alert_poller.py`) for health checks and crash reports.
  - [ ] Parse error traces, service endpoints, and HTTP status codes from email payloads.
- [ ] **7.2 Service Routing Matrix (`ROUTER.json`)**
  - [ ] Define service-to-machine, repo-path, and Herdr-pane mapping table.
  - [ ] Implement alert deduplication to group recurring error bursts into single incident tickets.
- [ ] **7.3 Dynamic Incident Dispatching**
  - [ ] Check target pane status (`idle` vs `working`).
  - [ ] If busy, dynamically split a sibling pane or git worktree in Herdr to handle the incident.
  - [ ] Format and prompt the incident reproduction criteria via `herdr agent prompt`.
- [ ] **7.4 Verification & Resolution Feedback**
  - [ ] Execute automated verification and health check curls against the patched service.
  - [ ] Auto-commit to a `fix/incident-<id>` branch and open a PR.
  - [ ] Auto-reply to the original alert email thread confirming remediation and test results.

---

## Phase 8: Zero-Touch Subscription Auto-Auth & Rate-Limit Bridge
- [ ] **8.1 Terminal OAuth URL & Device Code Interceptor**
  - [ ] Add regex pattern matching to `herdr_unblocker.py` for activation links (`claude.ai/activate`, `github.com/login/device`, etc.).
  - [ ] Extract one-time pairing codes and target activation URLs.
- [ ] **8.2 Chrome Background Auto-Approval Bridge (`herdr_auth_bridge.py`)**
  - [ ] Implement macOS AppleScript / Chrome helper to open activation URL in existing browser profile.
  - [ ] Auto-click "Approve / Authorize" button without requiring user interaction.
- [ ] **8.3 Inbound Email OTP Parser & Auto-Submitter**
  - [ ] Hook into email listener to extract 6-digit verification codes.
  - [ ] Inject OTP code directly into browser or terminal input prompt.
- [ ] **8.4 Rate-Limit Reset Timer & Auto-Resumer**
  - [ ] Parse rate-limit reset notices from terminal buffer (e.g. "Resets at 2:30 PM").
  - [ ] Place pane in scheduled countdown sleep and automatically prompt to resume work at reset timestamp.


