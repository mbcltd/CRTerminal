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

    /// Called on the main queue, coalesced across PTY chunks.
    var onUpdate: (@MainActor () -> Void)?
    /// Called on the main queue when the shell exits.
    var onExit: (@MainActor (Int32) -> Void)?
    /// Called on the main queue with a decoded OSC 52 clipboard payload.
    var onClipboard: (@MainActor (String) -> Void)?

    init(columns: Int, rows: Int) throws {
        terminal = OSAllocatedUnfairLock(initialState: Terminal(columns: columns, rows: rows))
        pty = try PTYSession(columns: columns, rows: rows)
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
        terminal.withLock { $0.state }
    }

    func send(_ bytes: [UInt8]) {
        pty.send(bytes)
    }

    func resize(columns: Int, rows: Int) {
        let changed = terminal.withLock { terminal in
            let before = (terminal.state.columns, terminal.state.rows)
            terminal.resize(columns: columns, rows: rows)
            return before != (columns, rows)
        }
        if changed {
            pty.resize(columns: columns, rows: rows)
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
        let (responses, clipboard) = terminal.withLock { terminal in
            data.withUnsafeBufferPointer { raw in
                terminal.feed(raw)
            }
            return (terminal.drainResponses(), terminal.drainClipboard())
        }
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
        scheduleUpdate()
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
