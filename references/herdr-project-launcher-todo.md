# herdr Project Launcher — TODO

Companion to [herdr-project-launcher.md](herdr-project-launcher.md) (usage) and
[herdr-project-launcher-plan.md](herdr-project-launcher-plan.md) (design record).

Status as of 2026-08-09: shipped and working. Everything below is optional
polish or follow-up.

## Now — decisions only Joel can make

- [ ] **Tune `CLI_MENU`** in [`bin/herdr-new-project`](../bin/herdr-new-project).
      Currently a working scaffold marked `TODO(joel)`, ordered
      `claude, codex, cursor-agent, opencode, gemini, pi, shell`. Open calls:
  - [ ] Does `claude` launch bare, or `claude --continue`?
  - [ ] Does `shell` earn a slot, given `prefix+c` already opens one?
  - [ ] Is `opencode` real usage or noise?
  - [ ] Order by actual frequency — fzf pre-selects the top entry.

- [ ] **Decide the project roots.** `~/Developer` holds only `ai-dotfiles`; real
      work has been under `~/Documents/Projects`. Either move projects into
      `~/Developer`, or widen the scan:

      ```toml
          command = "HERDR_PROJECT_ROOTS=$HOME/Developer:$HOME/Documents/Projects /Users/joggerjoel/.local/bin/herdr-new-project"
          ```

## Next — small, well-understood

- [ ] **README pointer.** The doc is not linked from anywhere. README reference
      links live inside topic-specific callouts; placement needs a judgement call.
- [ ] **Make the attach flag permanent.** `--remote-keybindings server` must be
      passed on every remote attach or the binding silently stops working. Wrap it
      in a shell alias or function on the client machine so it cannot be forgotten.
- [ ] **Ship the binding itself.** `~/.config/herdr/config.toml` is outside the
      repo, so a fresh machine gets the script but not the keybinding. Consider
      having `deploy.sh` or `setup.sh` append the block idempotently.
- [ ] **Declare the `fzf` dependency** wherever this repo records prerequisites,
      so provisioning a new host does not silently produce a broken key.

## Someday — only if a real need appears

Deliberately deferred; see the plan's rejected list for rationale.

- [ ] Jump to an existing tab when the project is already open, instead of
      creating a duplicate
- [ ] Recent / frecency ordering rather than alphabetical
- [ ] Workspace creation, not just tabs
- [ ] A preview pane in fzf showing `git log -1` / branch / dirty state

## Upstream — herdr bugs worth reporting

- [ ] **Kitty keyboard protocol not popped on exit.** After leaving herdr the
      shell echoes raw CSI-u sequences (`3;1:3u`, `442;5u`, `9;5u`) and becomes
      unusable until `reset`. herdr pushes the protocol on startup but does not
      emit the pop (`\033[<u`) on detach or exit. Workaround:

      ```bash
          printf '\033[<u'; stty sane; reset
          ```

- [ ] **`config reset-keys` is a blunt instrument.** It strips `[keys]`,
      `[keys.indexed]`, and _all_ `[[keys.command]]` blocks. There is no way to
      remove a single custom command. It also leaves orphaned comment lines behind.
- [ ] **`--remote-keybindings` default is a footgun.** Defaulting to `local`
      means a Node-side `[[keys.command]]` silently never fires for remote
      clients, with no warning and no diagnostic in `config check` or the reload
      response. A note in `herdr config check` output would have saved an
      afternoon.

## Known gaps in verification

- [ ] `--remote-keybindings server` is confirmed working by hand, never by an
      automated check. It runs on the client machine and cannot be tested from
      the Node.
- [ ] No test covers the picker against a root containing many repos — discovery
      and fzf have only ever seen a single-entry list.
