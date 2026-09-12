# Homebrew's installer writes this into ~/.zprofile. Re-assert it here so a
# missing or clobbered .zprofile cannot strip every brew binary from PATH.
# The runtime guards in modules.conf, such as `command -v pyenv`, depend on it.
if [[ ":$PATH:" != *":/opt/homebrew/bin:"* ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
