ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern cursor)
ZSH_HIGHLIGHT_PATTERNS=('sudo *' 'fg=green,bold' 'ls' 'fg=blue,bold')
ZSH_HIGHLIGHT_PATTERNS+=('rm -rf *' 'fg=white,bold,bg=red')

# git, history-substring-search, and vi-mode ship with oh-my-zsh core.
# zsh-autosuggestions, zsh-syntax-highlighting, and zsh-completions are
# third-party plugins; setup.sh's ensure_omz_plugins clones them into
# $ZSH_CUSTOM/plugins/ automatically (see modules.conf row 40) — no manual
# clone needed. Loading any of the six again by hand (as the old dotfiles
# did for the bundled ones) ran each one twice. zsh-fzf-history-search is
# intentionally absent here; it loads via zinit in modules/zinit.zsh instead
# (see that file).
plugins=(git
         zsh-autosuggestions
         zsh-syntax-highlighting
         zsh-completions
         history-substring-search
         vi-mode)

source "$ZSH/oh-my-zsh.sh"

# p10k's config must load after the theme itself, which oh-my-zsh.sh just
# sourced above — it can't live in modules/p10k.zsh without breaking that
# ordering (p10k.zsh runs before this module).
[[ ! -f "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"
