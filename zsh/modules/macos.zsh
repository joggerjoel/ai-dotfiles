[[ -e "$HOME/.iterm2_shell_integration.zsh" ]] && source "$HOME/.iterm2_shell_integration.zsh"

alias say="echo y | say"
alias subl='/Applications/Sublime\ Text.app/Contents/SharedSupport/bin/subl'

if [[ -d "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home" ]]; then
  export JAVA_HOME="/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home"
  export PATH="$JAVA_HOME/bin:$PATH"
fi

if [[ -d "/opt/homebrew/share/android-commandlinetools" ]]; then
  export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
  export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
fi
