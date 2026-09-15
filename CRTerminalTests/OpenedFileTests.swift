import AppKit
import Foundation
import Testing
import TerminalCore
@testable import CRTerminal

/// Files handed to the app by Launch Services (Dock-icon drop, double-click,
/// Finder "Open With"): folders open a shell, executables run, the rest is
/// refused — plus the command session that runs a script end to end.
struct OpenedFileTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crt-opened-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL, executable: Bool) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    // MARK: Classification

    @Test func folderOpensAShellThere() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(OpenedFile.action(for: dir) == .openShell(directory: dir.standardizedFileURL.path))
    }

    @Test func executableScriptRuns() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("go.command")
        try write("#!/bin/sh\necho hi\n", to: script, executable: true)
        #expect(OpenedFile.action(for: script) == .run(path: script.standardizedFileURL.path))
    }

    @Test func scriptWithoutExecuteBitIsRefused() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("go.sh")
        try write("#!/bin/sh\necho hi\n", to: script, executable: false)
        #expect(OpenedFile.action(for: script)
            == .notExecutable(path: script.standardizedFileURL.path))
    }

    @Test func missingFileIsReported() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ghost = dir.appendingPathComponent("nope.sh")
        #expect(OpenedFile.action(for: ghost) == .missing(path: ghost.standardizedFileURL.path))
    }

    // MARK: Command line + banner

    @Test func commandExecsTheEscapedPath() {
        #expect(OpenedFile.command(running: "/Users/dmb/My Scripts/go.command")
            == "exec '/Users/dmb/My Scripts/go.command'")
        #expect(OpenedFile.command(running: "/tmp/plain.sh") == "exec /tmp/plain.sh")
    }

    @Test func exitDescriptionsDecodeWaitStatus() {
        #expect(TerminalSession.exitDescription(status: 0) == "exit 0")
        #expect(TerminalSession.exitDescription(status: 3 << 8) == "exit 3")
        #expect(TerminalSession.exitDescription(status: 15).hasPrefix("killed by signal 15"))
    }

    @Test func bannerRestoresTheMainScreenOnlyWhenNeeded() {
        let plain = OpenedFile.completionBanner(
            status: 0, resetAlternateScreen: false, atLineStart: true)
        #expect(!plain.contains("?1049l"))
        #expect(!plain.contains("\r\n[Process"))
        #expect(plain.contains("[Process completed: exit 0]"))
        let fromAlt = OpenedFile.completionBanner(
            status: 0, resetAlternateScreen: true, atLineStart: false)
        #expect(fromAlt.hasPrefix("\u{1B}[?1049l"))
        #expect(fromAlt.contains("\r\n\u{1B}[1m[Process"))
    }

    // MARK: Live command session

    @Test @MainActor func commandSessionRunsTheScriptAndHoldsTheOutcome() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("go.command")
        try write("#!/bin/sh\necho \"in $(basename \"$PWD\")\"\nexit 3\n",
                  to: script, executable: true)
        let path = script.standardizedFileURL.path
        // /bin/sh as the "login shell" keeps the test independent of the
        // user's zsh profile output.
        let session = try TerminalSession(
            columns: 80, rows: 24, shell: "/bin/sh",
            command: OpenedFile.command(running: path),
            commandName: OpenedFile.displayName(for: path),
            workingDirectory: dir.path)
        #expect(session.commandName == "go.command")
        #expect(session.runningProcessName == "go.command")

        // The exit is recorded on the PTY's queue (the main-queue callback
        // is what the window controller uses; the state is what tests can
        // poll without a run loop).
        for _ in 0..<500 where !session.hasExited { usleep(10_000) }
        #expect(session.hasExited)
        #expect(session.exitStatus.map { TerminalSession.exitDescription(status: $0) } == "exit 3")
        #expect(session.runningProcessName == nil)
        var output = session.snapshot.lineText(0)
        for _ in 0..<500 where output.isEmpty {
            usleep(10_000)
            output = session.snapshot.lineText(0)
        }
        #expect(output == "in \(dir.lastPathComponent)")

        // The banner is injected by the window controller; here the raw
        // injection path lands it in the grid directly below the script's
        // output (echo left the cursor at the start of row 1).
        let state = session.snapshot
        session.inject(Array(OpenedFile.completionBanner(
            status: 3 << 8, resetAlternateScreen: state.isAlternateScreen,
            atLineStart: state.cursor.x == 0).utf8))
        var line = session.snapshot.lineText(1)
        for _ in 0..<500 where !line.contains("Process completed") {
            usleep(10_000)
            line = session.snapshot.lineText(1)
        }
        #expect(line == "[Process completed: exit 3]")
        #expect(session.snapshot.lineText(2) == "Press any key to close this session.")
    }

    /// A held pane routes its next keypress to the close request rather
    /// than the (dead) PTY.
    @Test @MainActor func heldPaneClosesOnNextKey() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var closeRequests = 0
        view.onCloseRequested = { closeRequests += 1 }
        let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        view.keyDown(with: key)
        #expect(closeRequests == 0)
        view.closesOnNextKey = true
        view.keyDown(with: key)
        #expect(closeRequests == 1)
    }
}
