# CRTerminal shell integration: emits OSC 133 prompt marks so the terminal
# can jump between prompts (⌘↑ / ⌘↓), record per-command exit status, and
# capture the typed command for the command-history palette (⌘⇧K / ⌘⌥K).
#
# crterm auto-injects this for zsh (via ZDOTDIR) — no setup needed. This
# standalone copy is for the cases auto-injection can't reach: sourcing it
# manually, or over SSH on a remote host. Keep it in sync with the embedded
# copy in CRTerminal/ShellIntegration.swift.
#
#   source /path/to/Scripts/shell-integration.zsh   # from ~/.zshrc

[[ $TERM_PROGRAM == crterm ]] || return 0

autoload -Uz add-zsh-hook

_crterminal_precmd() {
  local exit_code=$?
  # Close the previous command (133;D;exit) and mark a new prompt (133;A).
  printf '\e]133;D;%s\a\e]133;A\a' "$exit_code"
  # Append the command-start marker (133;B) to the end of the prompt so the
  # terminal can tell the typed command apart from the prompt. Re-applied each
  # prompt (idempotently) in case a prompt framework rebuilt PS1.
  if [[ $PS1 != *$'\e]133;B\a'* ]]; then
    PS1="${PS1}"$'%{\e]133;B\a%}'
  fi
}

_crterminal_preexec() {
  # Command output begins.
  printf '\e]133;C\a'
}

add-zsh-hook precmd _crterminal_precmd
add-zsh-hook preexec _crterminal_preexec
