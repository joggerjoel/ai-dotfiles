# Run the Herdr supervisor from any directory

Fleet zsh setup loads a `herdr-master` function. The existing `herdr` command
continues to address the Herdr terminal application.

```sh
herdr-master status
herdr-master goal "$PWD/goal.json"
herdr-master console
```

The function uses `~/Developer/herdr-orchestrator/herdr-master` and that checkout's
`.herdr-master` state root. It preserves your current directory and every argument.
The goal document and trusted profile select the target repository, not your current
directory. It does not start a daemon or install the orchestrator.

For a different installation, set these in `~/.zshrc.local`:

```sh
export HERDR_ORCHESTRATOR_DIR="/absolute/path/to/herdr-orchestrator"
export HERDR_STATE_ROOT="/absolute/path/to/supervisor-state"
```

After deploying ai-dotfiles, open a new zsh terminal or run `source ~/.zshrc`.
A missing checkout produces an explicit error instead of selecting another host
or creating supervisor state in the current project.

Fleet operators can run `ansible-playbook deploy-herdr-shell.yml` from
`ansible-ai/`. This copies only the shell module, registers it, backs up existing
configuration, and runs `setup.sh zsh`; it does not pull or reset host checkouts.
