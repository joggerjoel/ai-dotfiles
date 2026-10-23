# Temporary: reapply scripts/grok-bot-cli-v3-patch.sh after npm reinstalls
# grok-bot-cli, which overwrites the patch. Any successful global install or
# update triggers it; the script is a no-op when nothing needs patching.
# Remove with the script once ScriptedAlchemy/grok-bot-cli#149 is released.

_grok_bot_cli_patch="${${(%):-%x}:A:h:h:h}/scripts/grok-bot-cli-v3-patch.sh"

npm() {
  command npm "$@" || return
  local a
  for a in "$@"; do
    case "$a" in
      -g|--global|--location=global) bash "$_grok_bot_cli_patch"; return ;;
    esac
  done
}
