import AppKit

/// The "processes are still running" guard shown before a user-initiated
/// close or quit destroys live sessions — matching the prompt Terminal.app
/// and iTerm2 raise. Idle shells (and ignored multiplexers) never reach here;
/// see `TerminalSession.runningProcessName`.
enum CloseConfirmation {
    /// Asks whether to terminate the given running processes. Returns true to
    /// proceed, false to cancel. `names` must be non-empty; `verb` is the
    /// affirmative action word ("Quit" / "Close").
    @MainActor
    static func confirm(processNames names: [String], verb: String) -> Bool {
        precondition(!names.isEmpty)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if names.count == 1 {
            alert.messageText = "“\(names[0])” is still running."
            alert.informativeText = "\(verb)ing will terminate it."
        } else {
            // De-dup for the summary line: three shells running `vim` read as
            // "vim, vim, vim" otherwise.
            let unique = NSOrderedSet(array: names).array as? [String] ?? names
            alert.messageText = "\(names.count) processes are still running."
            alert.informativeText =
                "\(unique.joined(separator: ", ")) will be terminated."
        }
        let proceed = alert.addButton(withTitle: verb)
        proceed.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        // Escape cancels; Return triggers the (rightmost, default) verb button.
        cancel.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
