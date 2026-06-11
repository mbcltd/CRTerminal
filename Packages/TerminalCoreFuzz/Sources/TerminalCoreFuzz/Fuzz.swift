import TerminalCore

/// libFuzzer entry point. The invariant under test: no byte sequence may ever
/// crash, hang, or trap the parser or the screen model.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzTerminalCore(_ start: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let bytes = UnsafeBufferPointer(start: start, count: count)
    var terminal = Terminal(columns: 80, rows: 24)
    terminal.feed(bytes)
    // Split feeds must behave identically across chunk boundaries.
    if count > 2 {
        var chunked = Terminal(columns: 80, rows: 24)
        let mid = count / 2
        chunked.feed(UnsafeBufferPointer(rebasing: bytes[..<mid]))
        chunked.feed(UnsafeBufferPointer(rebasing: bytes[mid...]))
        precondition(chunked.state.lineText(0) == terminal.state.lineText(0))
    }
    return 0
}
