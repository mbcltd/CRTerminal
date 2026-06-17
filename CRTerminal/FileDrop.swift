import Foundation

/// Builds the text inserted when files are dropped onto a terminal pane
/// (issue #18). The separator and escaping depend on who is reading the
/// input, which bracketed-paste mode tells us:
///
/// - **Not bracketed** — a raw shell prompt is editing the line. Paths are
///   POSIX-shell-escaped and space-separated (a literal newline would *run*
///   the line after the first path), with a trailing space so the user can
///   keep typing arguments. Matches Terminal.app / Ghostty / iTerm2.
/// - **Bracketed** — an application has captured input (Claude Code, editors,
///   REPLs). The drop arrives as one atomic paste the app parses itself, so
///   newlines are safe and are what path-consuming tools expect: raw paths,
///   newline-separated, no shell quoting.
///
/// In *both* modes ASCII control characters are stripped from each path
/// first. A crafted filename like "\u{03}rm -rf ~\u{0D}.txt" would otherwise
/// inject Ctrl-C + a command + Enter and auto-run it — the drag-and-drop
/// command-execution bug class (e.g. CVE-2026-45038). Legitimate paths never
/// contain control characters.
enum FileDrop {
    /// The bytes-worth-of-text to paste for the given dropped paths, or an
    /// empty string when nothing survives sanitizing.
    static func payload(for paths: [String], bracketedPaste: Bool) -> String {
        let clean = paths.map(sanitize).filter { !$0.isEmpty }
        guard !clean.isEmpty else { return "" }
        if bracketedPaste {
            return clean.joined(separator: "\n")
        }
        return clean.map(shellEscape).joined(separator: " ") + " "
    }

    /// Strips ASCII control characters (the C0 range and DEL).
    static func sanitize(_ path: String) -> String {
        String(path.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
    }

    /// POSIX single-quote escaping, à la Python's `shlex.quote`: simple words
    /// (the shell-safe set) pass through untouched; anything else is wrapped
    /// in single quotes with embedded quotes broken out as `'\''`.
    static func shellEscape(_ word: String) -> String {
        if word.isEmpty { return "''" }
        let extra = Set("@%+=:,./-_".unicodeScalars)
        let safe = word.unicodeScalars.allSatisfy { s in
            (s.value >= 0x61 && s.value <= 0x7A)    // a-z
                || (s.value >= 0x41 && s.value <= 0x5A)  // A-Z
                || (s.value >= 0x30 && s.value <= 0x39)  // 0-9
                || extra.contains(s)
        }
        if safe { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
