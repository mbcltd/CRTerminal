import Foundation
import os

/// Automatic zsh shell integration, mirroring iTerm2's "inject automatically"
/// mode. Instead of asking the user to edit `~/.zshrc`, we point the spawned
/// shell at a generated `ZDOTDIR` whose `.zshenv` restores the user's real
/// startup environment and then loads our OSC 133 emitter *after* their
/// interactive config (so prompt frameworks like p10k/starship are already
/// set up). This is what powers the command-history palette (⌘⇧K / ⌘⌥K) and
/// prompt jumping (⌘↑ / ⌘↓).
///
/// Only zsh is auto-injected; other shells launch untouched and can use the
/// standalone `Scripts/shell-integration.zsh` (also the right choice over SSH,
/// which environment injection can't reach).
enum ShellIntegration {
    private nonisolated static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "mbcltd.crterm",
        category: "shell-integration")

    /// The OSC 133 emitter. Kept identical to `Scripts/shell-integration.zsh`
    /// (the manual/SSH copy) so behaviour matches whichever path loads it.
    private nonisolated static let integrationBody = """
    # crterm shell integration: emits OSC 133 prompt marks so the terminal can
    # jump between prompts (⌘↑ / ⌘↓), record per-command exit status, and
    # capture the typed command for the command-history palette (⌘⇧K / ⌘⌥K).

    [[ $TERM_PROGRAM == crterm ]] || return 0

    autoload -Uz add-zsh-hook

    _crterminal_precmd() {
      local exit_code=$?
      # Close the previous command (133;D;exit) and mark a new prompt (133;A).
      printf '\\e]133;D;%s\\a\\e]133;A\\a' "$exit_code"
      # Append the command-start marker (133;B) to the end of the prompt so the
      # terminal can tell the typed command apart from the prompt. Re-applied
      # each prompt (idempotently) in case a prompt framework rebuilt PS1.
      if [[ $PS1 != *$'\\e]133;B\\a'* ]]; then
        PS1="${PS1}"$'%{\\e]133;B\\a%}'
      fi
    }

    _crterminal_preexec() {
      # Command output begins.
      printf '\\e]133;C\\a'
    }

    add-zsh-hook precmd _crterminal_precmd
    add-zsh-hook preexec _crterminal_preexec
    """

    /// The `.zshenv` placed in our `ZDOTDIR`. zsh reads it first for every
    /// shell; it restores the real `ZDOTDIR` (so the user's other startup
    /// files — and any child shells — load normally) and defers our emitter
    /// until just before the first interactive prompt.
    private nonisolated static func bootstrap(integrationPath: String) -> String {
        let quoted = "'" + integrationPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        # crterm shell-integration bootstrap (auto-generated; safe to delete —
        # crterm regenerates it). Restores your real zsh startup, then loads
        # crterm's command-history integration after your interactive config.

        # 1. Hand ZDOTDIR back so .zprofile/.zshrc/.zlogin (and child shells)
        #    come from your normal location, not ours.
        if [[ -n "${CRTERM_ORIG_ZDOTDIR:-}" ]]; then
          export ZDOTDIR="$CRTERM_ORIG_ZDOTDIR"
        else
          unset ZDOTDIR
        fi
        unset CRTERM_ORIG_ZDOTDIR

        # 2. Source your real .zshenv, if present.
        _crterm_user_zdotdir="${ZDOTDIR:-$HOME}"
        [[ -r "$_crterm_user_zdotdir/.zshenv" ]] && source "$_crterm_user_zdotdir/.zshenv"
        unset _crterm_user_zdotdir

        # 3. Load the emitter after .zshrc via a one-shot precmd hook.
        if [[ -o interactive ]]; then
          autoload -Uz add-zsh-hook
          _crterm_bootstrap() {
            add-zsh-hook -d precmd _crterm_bootstrap
            source \(quoted)
          }
          add-zsh-hook precmd _crterm_bootstrap
        fi
        """
    }

    /// Materialises the ZDOTDIR + emitter into Application Support and returns
    /// the directory to use as `ZDOTDIR`. Rewritten every launch so emitter
    /// updates ship with the app. `nil` if the files can't be written (the
    /// shell then just launches without integration).
    private nonisolated static let preparedZDotDir: String? = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = base
            .appendingPathComponent("CRTerminal", isDirectory: true)
            .appendingPathComponent("ShellIntegration", isDirectory: true)
        let zdotdir = root.appendingPathComponent("zdotdir", isDirectory: true)
        let emitter = root.appendingPathComponent("crterm-integration.zsh")
        do {
            try FileManager.default.createDirectory(
                at: zdotdir, withIntermediateDirectories: true)
            try integrationBody.write(to: emitter, atomically: true, encoding: .utf8)
            try bootstrap(integrationPath: emitter.path)
                .write(to: zdotdir.appendingPathComponent(".zshenv"),
                       atomically: true, encoding: .utf8)
            return zdotdir.path
        } catch {
            log.error("could not prepare shell integration: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    /// If `shellPath` is zsh, redirect its startup through our ZDOTDIR,
    /// preserving any existing `ZDOTDIR` for restoration. No-op otherwise.
    nonisolated static func install(into environment: inout [String: String], shellPath: String) {
        guard (shellPath as NSString).lastPathComponent == "zsh",
              let zdotdir = preparedZDotDir else { return }
        if let existing = environment["ZDOTDIR"] {
            environment["CRTERM_ORIG_ZDOTDIR"] = existing
        }
        environment["ZDOTDIR"] = zdotdir
    }
}
