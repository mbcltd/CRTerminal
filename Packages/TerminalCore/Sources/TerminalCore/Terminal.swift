/// Parser + state, glued. The unit a session owns and feeds PTY bytes into.
public struct Terminal: Sendable {
    public private(set) var state: TerminalState
    private var parser = VTParser()

    public init(columns: Int, rows: Int) {
        state = TerminalState(columns: columns, rows: rows)
    }

    /// Seed a terminal from a restored snapshot (session restoration). The
    /// grid/scrollback come back as static text; the parser starts fresh, so
    /// the next PTY bytes (a new shell's first prompt) print below the
    /// restored cursor. See ARCHITECTURE.md "session restoration".
    public init(restoring snapshot: TerminalStateSnapshot) {
        state = TerminalState(restoring: snapshot)
    }

    public var scrollbackLimit: Int {
        get { state.scrollbackLimit }
        set { state.scrollbackLimit = newValue }
    }

    public mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        parser.feed(bytes, handler: &state)
    }

    public mutating func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    public mutating func resize(columns: Int, rows: Int) {
        state.resize(columns: columns, rows: rows)
    }

    /// Cell size in device pixels (points × backing scale), from the
    /// renderer. Drives inline-image pixel↔cell math and CSI 14/16 t.
    public mutating func setCellPixelSize(width: Int, height: Int) {
        state.setCellPixelSize(width: width, height: height)
    }

    /// Bytes the terminal wants written back to the PTY (DSR/DA responses).
    public mutating func drainResponses() -> [UInt8] {
        defer { state.responses.removeAll(keepingCapacity: true) }
        return state.responses
    }

    /// Raw OSC 52 payload (base64) awaiting clipboard write, if any.
    public mutating func drainClipboard() -> String? {
        defer { state.pendingClipboard = nil }
        return state.pendingClipboard
    }

    /// Desktop notifications (OSC 9 / OSC 777;notify) awaiting delivery.
    public mutating func drainNotifications() -> [TerminalNotification] {
        defer { state.pendingNotifications.removeAll(keepingCapacity: true) }
        return state.pendingNotifications
    }
}
