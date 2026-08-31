ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern cursor)
ZSH_HIGHLIGHT_PATTERNS=('sudo *' 'fg=green,bold' 'ls' 'fg=blue,bold')
ZSH_HIGHLIGHT_PATTERNS+=('rm -rf *' 'fg=white,bold,bg=red')

# zsh-syntax-highlighting and history-substring-search are omz's own
# custom/bundled plugins — loading them again by hand (as the old dotfiles
# did) ran each one twice. zsh-fzf-history-search is intentionally absent
# here; it loads via zinit in modules/zinit.zsh instead (see that file).
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
