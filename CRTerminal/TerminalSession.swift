import Foundation
import TerminalCore
import os

/// Glues a PTY to a Terminal: PTY bytes are parsed on the IO queue under the
/// state lock; the view pulls value snapshots. See ARCHITECTURE.md
/// "Concurrency model".
/// All mutable state lives behind OSAllocatedUnfairLocks.
nonisolated final class TerminalSession: @unchecked Sendable {
    private let terminal: OSAllocatedUnfairLock<Terminal>
    private let pty: PTYSession
    private let updatePending = OSAllocatedUnfairLock(initialState: false)
    /// Latest device-pixel cell size from the renderer, used to size the PTY
    /// winsize in pixels (ws_xpixel/ws_ypixel) alongside its rows/columns.
    private let cellPixelSize = OSAllocatedUnfairLock(initialState: (width: 0, height: 0))
    /// Pending safety-timeout for synchronized output (DEC ?2026): armed while
    /// the mode buffers frames, fired if the app never sends the closing `l`.
    private let syncTimeout = OSAllocatedUnfairLock<DispatchWorkItem?>(initialState: nil)
    /// Matches the ~150 ms cap xterm/contour use, so a buggy program can't
    /// freeze the display indefinitely.
    private static let synchronizedOutputTimeout: TimeInterval = 0.15

    /// Called on the main queue, coalesced across PTY chunks.
    var onUpdate: (@MainActor () -> Void)?
    /// Called on the main queue when the shell exits.
    var onExit: (@MainActor (Int32) -> Void)?
    /// Called on the main queue with a decoded OSC 52 clipboard payload.
    var onClipboard: (@MainActor (String) -> Void)?
    /// Called on the main queue with OSC 9/777 desktop notifications.
    var onNotification: (@MainActor (TerminalNotification) -> Void)?

    /// `restoringFrom` seeds the terminal with a saved snapshot before the
    /// PTY attaches, so the restored grid/scrollback paint as static text and
    /// the fresh shell's first prompt prints below them (ARCHITECTURE.md
    /// "session restoration"). The PTY is sized to the restored grid so the
    /// shell's winsize matches what the user sees until the view reflows.
    init(columns: Int, rows: Int, shell: String? = nil,
         workingDirectory: String? = nil, scrollbackLines: Int = 10_000,
         lightBackground: Bool = false,
         restoringFrom snapshot: TerminalStateSnapshot? = nil) throws {
        var seeded = snapshot.map(Terminal.init(restoring:))
            ?? Terminal(columns: columns, rows: rows)
        seeded.scrollbackLimit = max(0, scrollbackLines)
        let ptyColumns = seeded.state.columns
        let ptyRows = seeded.state.rows
        terminal = OSAllocatedUnfairLock(initialState: seeded)
        pty = try PTYSession(
            columns: ptyColumns, rows: ptyRows, shell: shell,
            workingDirectory: workingDirectory, lightBackground: lightBackground)
        pty.onData = { [weak self] data in
            self?.ingest(data)
        }
        pty.onExit = { [weak self] status in
            DispatchQueue.main.async {
                self?.onExit?(status)
            }
        }
    }

    var snapshot: TerminalState {
        // `displaySnapshot` holds the frame frozen at the start of a
        // synchronized-output frame (?2026) so consumers never see a
        // half-composed grid; otherwise it's the live state.
        terminal.withLock { $0.state.displaySnapshot }
    }

    /// The shell's pid (sidebar metadata: cwd, process rows).
    var shellProcessID: pid_t { pty.processID }

    /// Foreground process group on the PTY; equals the shell's pid when
    /// nothing is running.
    var foregroundProcessGroup: pid_t { pty.foregroundProcessGroup }

    func send(_ bytes: [UInt8]) {
        pty.send(bytes)
    }

    /// Device-pixel cell size from the renderer; lets the graphics protocols
    /// map image pixels to cells and answer CSI 14/16 t.
    func setCellPixelSize(width: Int, height: Int) {
        terminal.withLock { $0.setCellPixelSize(width: width, height: height) }
        let changed = cellPixelSize.withLock { size -> Bool in
            guard (width, height) != (size.width, size.height) else { return false }
            size = (width, height)
            return true
        }
        // Re-report the PTY winsize so ws_xpixel/ws_ypixel track the new cell
        // size even when the grid (rows/columns) is unchanged — e.g. a font
        // size change. resize() covers the grid-changed case.
        guard changed else { return }
        let (cols, rows) = terminal.withLock { ($0.state.columns, $0.state.rows) }
        pty.resize(columns: cols, rows: rows,
                   pixelWidth: cols * width, pixelHeight: rows * height)
    }

    /// The foreground/background the active scheme paints with, so OSC 10/11
    /// color queries answer with the live colors and programs can detect a
    /// light vs dark terminal (issue #8).
    func setColors(
        foreground: (red: UInt8, green: UInt8, blue: UInt8),
        background: (red: UInt8, green: UInt8, blue: UInt8)
    ) {
        terminal.withLock { $0.setColors(foreground: foreground, background: background) }
    }

    func resize(columns: Int, rows: Int) {
        let changed = terminal.withLock { terminal in
            let before = (terminal.state.columns, terminal.state.rows)
            terminal.resize(columns: columns, rows: rows)
            return before != (columns, rows)
        }
        if changed {
            let cell = cellPixelSize.withLock { $0 }
            pty.resize(columns: columns, rows: rows,
                       pixelWidth: columns * cell.width, pixelHeight: rows * cell.height)
            scheduleUpdate()
        }
    }

    func terminate() {
        pty.terminate()
    }

    /// CRT_TYPIST_CAPTURE=1: append every ingested PTY byte to
    /// /tmp/crterminal-bytes.bin for replay debugging and golden tests.
    private static let captureURL: URL? = {
        guard ProcessInfo.processInfo.environment["CRT_TYPIST_CAPTURE"] != nil else { return nil }
        let url = URL(fileURLWithPath: "/tmp/crterminal-bytes.bin")
        try? Data().write(to: url)
        return url
    }()

    private func ingest(_ data: [UInt8]) {
        if let url = Self.captureURL,
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(data))
            try? handle.close()
        }
        let (responses, clipboard, notifications, syncActive) = terminal.withLock { terminal in
            data.withUnsafeBufferPointer { raw in
                terminal.feed(raw)
            }
            return (terminal.drainResponses(), terminal.drainClipboard(),
                    terminal.drainNotifications(), terminal.isSynchronizedOutputActive)
        }
        updateSynchronizedOutputTimeout(active: syncActive)
        if !responses.isEmpty {
            pty.send(responses)
        }
        if let clipboard,
           let decoded = Data(base64Encoded: clipboard),
           let text = String(data: decoded, encoding: .utf8) {
            DispatchQueue.main.async {
                self.onClipboard?(text)
            }
        }
        if !notifications.isEmpty {
            DispatchQueue.main.async {
                for notification in notifications {
                    self.onNotification?(notification)
                }
            }
        }
        scheduleUpdate()
    }

    /// Arm the safety timeout when synchronized output becomes active, cancel
    /// it when the app closes the frame (`CSI ? 2026 l`). The deadline is a
    /// hard cap from when the mode opened: re-entry while already armed keeps
    /// the original deadline rather than extending it.
    private func updateSynchronizedOutputTimeout(active: Bool) {
        syncTimeout.withLock { pending in
            if active {
                guard pending == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    self?.expireSynchronizedOutput()
                }
                pending = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.synchronizedOutputTimeout, execute: work)
            } else {
                pending?.cancel()
                pending = nil
            }
        }
    }

    private func expireSynchronizedOutput() {
        syncTimeout.withLock { $0 = nil }
        let flushed = terminal.withLock { terminal -> Bool in
            guard terminal.isSynchronizedOutputActive else { return false }
            terminal.expireSynchronizedOutput()
            return true
        }
        if flushed { scheduleUpdate() }
    }

    private func scheduleUpdate() {
        let alreadyPending = updatePending.withLock { pending in
            defer { pending = true }
            return pending
        }
        guard !alreadyPending else { return }
        DispatchQueue.main.async {
            self.updatePending.withLock { $0 = false }
            self.onUpdate?()
        }
    }
}
