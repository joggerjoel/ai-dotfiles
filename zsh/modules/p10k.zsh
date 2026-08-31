typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet

# Should stay as close to the top of the shell's startup as practical —
# anything that prints before this block breaks the instant-prompt cache.
# It runs after modules/zinit.zsh and modules/omz.zsh only because neither
# produces output on a normal run (zinit's one-time bootstrap clone is the
# sole exception, matching the original file's own layout).
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi
