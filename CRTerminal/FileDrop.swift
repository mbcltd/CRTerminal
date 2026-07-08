import Foundation

/// Builds the text inserted when files are dropped onto a terminal pane
/// (issue #18). Paths are POSIX-shell-escaped and space-separated, with a
/// trailing space so the user can keep typing arguments — matching
/// Terminal.app / Ghostty / iTerm2. The same payload is used whether a raw
/// shell prompt or an application (bracketed paste) is reading the input:
/// escaping keeps paths containing spaces unambiguous either way, and a
/// space separator never *runs* the line the way a newline would at a
/// prompt.
///
/// ASCII control characters are stripped from each path first. A crafted
/// filename like "\u{03}rm -rf ~\u{0D}.txt" would otherwise inject Ctrl-C +
/// a command + Enter and auto-run it — the drag-and-drop command-execution
/// bug class (e.g. CVE-2026-45038). Legitimate paths never contain control
/// characters.
enum FileDrop {
    /// The bytes-worth-of-text to paste for the given dropped paths, or an
    /// empty string when nothing survives sanitizing.
    static func payload(for paths: [String]) -> String {
        let clean = paths.map(sanitize).filter { !$0.isEmpty }
        guard !clean.isEmpty else { return "" }
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
