# Install must precede source: sourcing zinit.zsh before it exists on a
# fresh machine failed every time (the old dotfiles did both, in that order).
if [[ ! -f "$HOME/.local/share/zinit/zinit.git/zinit.zsh" ]]; then
  command mkdir -p "$HOME/.local/share/zinit" && command chmod g-rwX "$HOME/.local/share/zinit"
  command git clone https://github.com/zdharma-continuum/zinit "$HOME/.local/share/zinit/zinit.git"
fi

source "$HOME/.local/share/zinit/zinit.git/zinit.zsh"
autoload -Uz _zinit
(( ${+_comps} )) && _comps[zinit]=_zinit

zinit light-mode for \
    zdharma-continuum/zinit-annex-as-monitor \
    zdharma-continuum/zinit-annex-bin-gem-node \
    zdharma-continuum/zinit-annex-patch-dl \
    zdharma-continuum/zinit-annex-rust

# zsh-fzf-history-search lives here, not in modules/plugins.zsh's omz plugins
# array: zinit self-installs the repo, while an omz custom plugin needs a
# manual clone into custom/plugins first. Loading it both ways doubled it.
zinit ice lucid wait'0'
zinit light joshskidmore/zsh-fzf-history-search
