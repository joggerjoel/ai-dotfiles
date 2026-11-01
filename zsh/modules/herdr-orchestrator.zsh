# Keep `herdr` available for the terminal application's own CLI.
# Set overrides in ~/.zshrc.local when the checkout or supervisor root differs.
herdr-master() {
  local checkout="${HERDR_ORCHESTRATOR_DIR:-$HOME/Developer/herdr-orchestrator}"
  local state_root="${HERDR_STATE_ROOT:-$checkout/.herdr-master}"
  if [[ ! -x "$checkout/herdr-master" ]]; then
    print -u2 -- "herdr-master: executable not found at $checkout/herdr-master; set HERDR_ORCHESTRATOR_DIR to your orchestrator checkout."
    return 127
  fi
  "$checkout/herdr-master" --root "$state_root" "$@"
}
