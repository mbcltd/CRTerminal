# CRTerminal shell integration: emits OSC 133 prompt marks so the terminal
# can jump between prompts (⌘↑ / ⌘↓) and record per-command exit status.
#
#   source /path/to/Scripts/shell-integration.zsh   # from ~/.zshrc

[[ $TERM_PROGRAM == CRTerminal ]] || return 0

autoload -Uz add-zsh-hook

_crterminal_precmd() {
  local exit_code=$?
  # Close the previous command (133;D;exit) and mark a new prompt (133;A).
  printf '\e]133;D;%s\a\e]133;A\a' "$exit_code"
}

_crterminal_preexec() {
  # Command output begins.
  printf '\e]133;C\a'
}

add-zsh-hook precmd _crterminal_precmd
add-zsh-hook preexec _crterminal_preexec
