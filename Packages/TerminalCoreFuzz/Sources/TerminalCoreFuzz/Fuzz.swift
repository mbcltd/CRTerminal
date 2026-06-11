import TerminalCore

/// libFuzzer entry point. The invariant under test: no byte sequence may ever
/// crash, hang, or trap the parser. Once the VT parser lands (Phase 1) this
/// feeds it directly; until then it exercises nothing but proves the harness.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzTerminalCore(_ start: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    let bytes = UnsafeBufferPointer(start: start, count: count)
    // TODO(Phase 1): var parser = VTParser(); parser.feed(bytes)
    _ = bytes
    return 0
}
