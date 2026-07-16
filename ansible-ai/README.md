# ansible-ai

Fleet provisioning + updates for the aorus servers, driven from the MacBook Pro
(control node). Lives inside `ai-dotfiles` so the config it deploys and the
automation that deploys it version together.

Makes the `<host>-claude` SSH aliases in `~/.ssh/config` fully functional by
provisioning each aorus box in two stages.

**Stage A — runtime** (so the alias's `RemoteCommand` works at all):

| Piece                  | Why                                           |
| ---------------------- | --------------------------------------------- |
| `~/Documents/Projects` | the `cd` target in the alias                  |
| `tmux`                 | session persistence (`tmux new -A -s claude`) |
| `~/.local/bin/claude`  | the Claude Code **binary** the alias launches |

**Stage B — config** (so remote claude behaves like your local setup):

| Piece                                  | Why                                              |
| -------------------------------------- | ------------------------------------------------ |
| base deps (git/jq/curl)                | so `setup.sh` needn't sudo mid-run               |
| clone `joggerjoel/ai-dotfiles`         | the config source                                |
| `setup.sh` **vps profile**, unattended | CLAUDE.md, core plugin stack, guardrails, memory |

Without Stage B, `ssh aorusN-claude` gives **vanilla** Claude Code (no plugins/
skills/MCP). Toggle Stage B with `install_dotfiles` in `inventory.local.yml`.

The jump host (ProxyJump) is baked into `inventory.local.yml`, so this does
**not** depend on `~/.ssh/config`. That file is **gitignored** — real IPs,
jump hosts, and usernames never go in the tracked repo. First-time setup:

```bash
cp inventory.example.yml inventory.local.yml   # then fill in your hosts
```

## Unattended answers seeded into setup.sh

`printf '2\n<github_user>\n<hide_ai>\n' | bash setup.sh` — then EOF drives the rest
to safe defaults:

| Prompt              | Seeded                             | Source                                     |
| ------------------- | ---------------------------------- | ------------------------------------------ |
| Machine type        | `2` = **vps**                      | must override (default is desktop)         |
| GitHub username     | `joggerjoel`                       | `dotfiles_github_user`                     |
| Hide AI attribution | `y`                                | `dotfiles_hide_ai` (matches commit policy) |
| MCP integrations    | _(EOF)_ → skip                     | add later: `./setup.sh add <name>`         |
| Supabase            | _(EOF)_ → skip (default 3)         | —                                          |
| Plugin stack        | _(EOF)_ → install core (default y) | optional groups default n                  |

## Usage

```bash
cd ~/Developer/Git/ai-dotfiles/ansible-ai   # or: cd <repo>/ansible-ai

ansible aorus_ai -m ping                       # reachability
ansible-playbook provision-ai.yml --check      # dry run
ansible-playbook provision-ai.yml -K           # apply (-K = sudo password)

ansible-playbook provision-ai.yml -K --limit aorus4,aorus5   # subset
```

### Update the whole fleet (the everyday command)

After pushing config changes to `github.com/joggerjoel/ai-dotfiles`, propagate
them to every server **and this Mac** in one shot:

```bash
ansible-playbook update.yml            # claude update + setup.sh update, servers + local
ansible-playbook update.yml --check    # dry run
ansible-playbook update.yml --limit aorus7    # one server
ansible-playbook update.yml --limit aorus_ai  # servers only (skip local)
ansible-playbook update.yml --limit local_ai  # this Mac only
```

`update.yml` targets the `ai_all` group = the aorus servers (`aorus_ai`) **plus the
local control node** (`local_ai` → `localhost` via `ansible_connection: local`). The
Mac gets the same treatment as a server — `claude update`, the sibling model-CLI
upgrades (codex/cursor/cortex/opencode/gemini via `scripts/agents-update.sh`, the same
script `./update.sh` runs locally), and `setup.sh update` (plugins/skills +
its saved **desktop** profile). No SSH is used for the Mac, so it works regardless
of which network you're on. `provision-ai.yml` stays servers-only — the control node
is never provisioned.

> The local node is folded into Ansible for convenience. The direct path still
> works identically for just this Mac: `cd ~/Developer/Git/ai-dotfiles && ./setup.sh update`.

`update.yml` upgrades the Claude Code **binary** (`claude update`) and refreshes the
**config** (`setup.sh update` → `git pull --rebase --autostash` + re-apply the saved
vps profile). That config refresh now also **refreshes the plugin/skill stack**:
`setup.sh update` runs `bootstrap-plugins.sh --core-only`, which pulls the latest
marketplace catalogs (so installed plugins update on the next Claude Code start) and
installs any newly-listed CORE plugins. No `-K` needed — no package installs.

- `-K` (on `provision-ai.yml`) prompts for the sudo password (needed to install
  tmux/git/jq). Drop it on hosts with passwordless sudo.
- **Runtime only, skip dotfiles:** `-e install_dotfiles=false`.
- **Re-provision from scratch** on a host: the setup step is guarded by
  `~/.claude/settings.json`; delete that file to force a full re-setup.

## Syncing the inventory from `~/.ssh/config`

`inventory.local.yml` is the source of truth for which servers the playbooks target.
Instead of hand-editing it, run:

```bash
./ssh-ansible-sync.sh            # interactive checklist
./ssh-ansible-sync.sh --dry-run  # preview the resulting hosts: block, write nothing
./ssh-ansible-sync.sh --yes      # non-interactive: keep exactly the current hosts
```

It parses every `Host` in `~/.ssh/config` and shows a checklist. Hosts **already in
`inventory.local.yml` start checked** `[x]`; the rest start `[ ]`. Toggle by number
(`a`=all, `n`=none, `d`=done), confirm, and only the `hosts:` block is rewritten —
the group `vars:` (user, ProxyJump, dotfiles vars) is preserved, and a `.bak` is
saved.

- Excludes wildcard `Host *` and the derived `*-claude` aliases automatically.
- Adds a per-host `ansible_user` only when it differs from the group default.
- Warns if a selected host's `ProxyJump` differs from the group's.

## Notes

- Idempotent — safe against all aorus hosts even though aorus6/7/8 are already done.
- Offline hosts are reported unreachable and skipped; the rest still run.
- macstudio is intentionally excluded (macOS, uses `screen`, no apt); provision it
  separately if needed.

## After a successful run

```bash
ssh aorus4-claude   # jump -> cd ~/Documents/Projects -> persistent, fully-configured claude
```
