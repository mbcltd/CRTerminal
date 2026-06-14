import AppKit
import TerminalCore

/// Debug-only end-to-end probe (CRT_RESTORE_PROBE=1) for session restoration
/// R1. It drives the whole loop in one process — type output, save the
/// session to disk via `SessionStateStore`, then reopen a restored session —
/// and reports whether the typed marker and working directory came back. The
/// manual Debug-menu items cover true cross-relaunch restore; this gives the
/// loop automated coverage. Writes /tmp/crterminal-restore.txt and exits.
@MainActor
final class RestoreProbe {
    private weak var controller: TerminalWindowController?
    private let marker = "RESTORE_MARKER_4242"

    init(controller: TerminalWindowController) {
        self.controller = controller
    }

    func start() {
        // Let the restored shell's predecessor print its prompt first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            type("cd /tmp\recho \(marker)\r")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                saveAndRestore()
            }
        }
    }

    private func type(_ string: String) {
        controller?.focusedPane?.send(Array(string.utf8))
    }

    private func saveAndRestore() {
        guard let controller,
              let id = controller.saveFocusedSessionState() else {
            finish(["FAIL: no focused session to save"])
            return
        }
        // Save is async; give the io queue a beat, then read it back and
        // restore from the round-tripped snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard let snapshot = SessionStateStore.shared.load(for: id) else {
                finish(["FAIL: saved state \(id) did not load back"])
                return
            }
            controller.restoreSession(from: snapshot)
            // Let the restored grid paint and the fresh shell start.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
                report(restoredID: id, hint: snapshot.workingDirectoryHint)
                SessionStateStore.shared.discard(id: id)
            }
        }
    }

    private func report(restoredID: UUID, hint: String?) {
        guard let controller, let pane = controller.focusedPane,
              let session = pane.session else {
            finish(["FAIL: no restored pane"])
            return
        }
        let state = session.snapshot
        var lines: [String] = ["=== CRT_RESTORE REPORT ==="]
        lines.append("saved/restored id: \(restoredID)")
        lines.append("working directory hint: \(hint ?? "nil")")

        // The restored static text lives in scrollback + the visible grid.
        let allText = state.scrollback.map(Self.text(of:))
            + (0..<state.rows).map { state.lineText($0) }
        let markerBack = allText.contains { $0.contains(marker) }
        lines.append("marker restored as static text: \(markerBack)")

        let shellCWD = SessionInfo.workingDirectory(of: session.shellProcessID)
        lines.append("fresh shell cwd: \(shellCWD ?? "nil")")
        lines.append("fresh shell cwd is /tmp: \(shellCWD == "/tmp" || shellCWD == "/private/tmp")")

        for (y, text) in allText.enumerated() where !text.isEmpty {
            lines.append("line \(y): \(text)")
        }
        let pass = markerBack && (shellCWD == "/tmp" || shellCWD == "/private/tmp")
        lines.append("RESULT: \(pass ? "PASS" : "FAIL")")
        finish(lines)
    }

    /// Row text with trailing blanks trimmed (scrollback rows aren't exposed
    /// as strings the way the active grid is via `lineText`).
    private static func text(of row: [Cell]) -> String {
        var scalars = String.UnicodeScalarView()
        for cell in row where !cell.attributes.contains(.wideSpacer) {
            scalars.append(Unicode.Scalar(cell.glyph) ?? "\u{FFFD}")
        }
        var text = String(scalars)
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    private func finish(_ lines: [String]) {
        let text = (lines + ["=== END REPORT ==="]).joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(text.utf8))
        try? text.write(
            toFile: "/tmp/crterminal-restore.txt", atomically: true, encoding: .utf8)
        exit(0)
    }
}
