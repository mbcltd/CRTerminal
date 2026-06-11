/// Parser + state, glued. The unit a session owns and feeds PTY bytes into.
public struct Terminal: Sendable {
    public private(set) var state: TerminalState
    private var parser = VTParser()

    public init(columns: Int, rows: Int) {
        state = TerminalState(columns: columns, rows: rows)
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

    /// Bytes the terminal wants written back to the PTY (DSR/DA responses).
    public mutating func drainResponses() -> [UInt8] {
        defer { state.responses.removeAll(keepingCapacity: true) }
        return state.responses
    }
}
