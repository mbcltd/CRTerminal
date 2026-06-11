/// Semantic sink for the parser. `TerminalState` is the production handler;
/// tests use recording handlers to verify syntax separately from semantics.
public protocol TerminalHandler {
    mutating func printScalar(_ scalar: Unicode.Scalar)
    /// Bulk fast path for runs of printable ASCII (0x20–0x7E). The default
    /// forwards per scalar; `TerminalState` overrides with chunked writes.
    mutating func printASCIIRun(_ bytes: UnsafeBufferPointer<UInt8>)
    mutating func executeControl(_ byte: UInt8)
    mutating func escapeDispatch(final: UInt8, intermediates: [UInt8])
    mutating func csiDispatch(_ sequence: CSISequence)
    mutating func oscDispatch(_ payload: [UInt8])
}

extension TerminalHandler {
    public mutating func printASCIIRun(_ bytes: UnsafeBufferPointer<UInt8>) {
        for byte in bytes {
            printScalar(Unicode.Scalar(byte))
        }
    }
}

public struct CSISequence: Sendable, Equatable {
    /// Private-use leading byte: '?', '>', '<' or '='.
    public var prefix: UInt8?
    public var params: [Int]
    public var intermediates: [UInt8]
    public var final: UInt8

    public init(prefix: UInt8? = nil, params: [Int] = [], intermediates: [UInt8] = [], final: UInt8) {
        self.prefix = prefix
        self.params = params
        self.intermediates = intermediates
        self.final = final
    }

    public func param(_ index: Int, default defaultValue: Int = 0) -> Int {
        index < params.count ? params[index] : defaultValue
    }

    /// Movement-count semantics: a missing or zero parameter means 1.
    public func count(_ index: Int = 0) -> Int {
        max(1, param(index))
    }
}

/// Syntax-level VT parser following the VT500-series state machine
/// (vt100.net/emu/dec_ansi_parser) with incremental UTF-8 decoding in front.
/// Resumable across arbitrary chunk boundaries; total over arbitrary input.
public struct VTParser: Sendable {
    private enum State: Sendable {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case oscString
        /// DCS/SOS/PM/APC: consumed and discarded until ST.
        case otherString
    }

    private static let maxParams = 32
    private static let maxOSCBytes = 4096

    private var state = State.ground

    // Incremental UTF-8 decoding.
    private var utf8Remaining = 0
    private var utf8Scalar: UInt32 = 0
    private var utf8Minimum: UInt32 = 0

    // CSI accumulation.
    private var prefix: UInt8?
    private var params: [Int] = []
    private var currentParam: Int?
    private var intermediates: [UInt8] = []

    // OSC accumulation.
    private var oscBuffer: [UInt8] = []
    /// Saw ESC inside a string state; the next byte decides ST vs. abort.
    private var stringEscape = false

    public init() {}

    public mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>, handler: inout some TerminalHandler) {
        var i = 0
        let count = bytes.count
        while i < count {
            let byte = bytes[i]
            // Fast path: a run of printable ASCII in ground state goes to the
            // handler in one call instead of per-byte dispatch.
            if state == .ground, utf8Remaining == 0, byte &- 0x20 < 0x5F {
                var j = i + 1
                while j < count, bytes[j] &- 0x20 < 0x5F {
                    j += 1
                }
                handler.printASCIIRun(UnsafeBufferPointer(rebasing: bytes[i..<j]))
                i = j
            } else {
                consume(byte, &handler)
                i += 1
            }
        }
    }

    public mutating func feed(_ bytes: [UInt8], handler: inout some TerminalHandler) {
        bytes.withUnsafeBufferPointer { feed($0, handler: &handler) }
    }

    private mutating func consume(_ byte: UInt8, _ handler: inout some TerminalHandler) {
        switch state {
        case .ground: ground(byte, &handler)
        case .escape: escape(byte, &handler)
        case .escapeIntermediate: escapeIntermediate(byte, &handler)
        case .csiEntry, .csiParam, .csiIntermediate: csi(byte, &handler)
        case .csiIgnore: csiIgnore(byte, &handler)
        case .oscString: oscString(byte, &handler)
        case .otherString: otherString(byte, &handler)
        }
    }

    // MARK: Ground + UTF-8

    private mutating func ground(_ byte: UInt8, _ handler: inout some TerminalHandler) {
        if utf8Remaining > 0 {
            if byte & 0xC0 == 0x80 {
                utf8Scalar = utf8Scalar << 6 | UInt32(byte & 0x3F)
                utf8Remaining -= 1
                if utf8Remaining == 0 {
                    emitDecodedScalar(&handler)
                }
                return
            }
            // Truncated sequence: emit a replacement, reprocess this byte.
            utf8Remaining = 0
            handler.printScalar("\u{FFFD}")
        }

        switch byte {
        case 0x1B:
            enterEscape()
        case 0x00..<0x20, 0x7F:
            handler.executeControl(byte)
        case 0x20..<0x7F:
            handler.printScalar(Unicode.Scalar(byte))
        case 0xC2...0xDF:
            startUTF8(byte & 0x1F, remaining: 1, minimum: 0x80)
        case 0xE0...0xEF:
            startUTF8(byte & 0x0F, remaining: 2, minimum: 0x800)
        case 0xF0...0xF4:
            startUTF8(byte & 0x07, remaining: 3, minimum: 0x1_0000)
        default:
            // 0x80–0xC1 (stray continuation / overlong lead), 0xF5–0xFF.
            handler.printScalar("\u{FFFD}")
        }
    }

    private mutating func startUTF8(_ initial: UInt8, remaining: Int, minimum: UInt32) {
        utf8Scalar = UInt32(initial)
        utf8Remaining = remaining
        utf8Minimum = minimum
    }

    private mutating func emitDecodedScalar(_ handler: inout some TerminalHandler) {
        let value = utf8Scalar
        if value >= utf8Minimum, let scalar = Unicode.Scalar(value) {
            // Scalar(_:UInt32) rejects surrogates and > 0x10FFFF.
            handler.printScalar(scalar)
        } else {
            handler.printScalar("\u{FFFD}")
        }
    }

    // MARK: Escape

    private mutating func enterEscape() {
        state = .escape
        utf8Remaining = 0
        intermediates.removeAll(keepingCapacity: true)
    }

    private mutating func escape(_ byte: UInt8, _ handler: inout some TerminalHandler) {
        switch byte {
        case 0x1B:
            enterEscape()
        case 0x5B: // '['
            state = .csiEntry
            prefix = nil
            params.removeAll(keepingCapacity: true)
            currentParam = nil
            intermediates.removeAll(keepingCapacity: true)
        case 0x5D: // ']'
            state = .oscString
            oscBuffer = []
            stringEscape = false
        case 0x50, 0x58, 0x5E, 0x5F: // DCS, SOS, PM, APC
            state = .otherString
            stringEscape = false
        case 0x20...0x2F:
            intermediates = [byte]
            state = .escapeIntermediate
        case 0x00..<0x20:
            handler.executeControl(byte)
        case 0x7F:
            break
        default: // 0x30–0x7E final byte
            handler.escapeDispatch(final: byte, intermediates: [])
            state = .ground
        }
    }

    private mutating func escapeIntermediate(_ byte: UInt8, _ handler: inout some TerminalHandler) {
        switch byte {
        case 0x1B:
            enterEscape()
        case 0x20...0x2F:
            if intermediates.count < 2 { intermediates.append(byte) }
        case 0x00..<0x20:
            handler.executeControl(byte)
        case 0x7F:
            break
        default:
            handler.escapeDispatch(final: byte, intermediates: intermediates)
            state = .ground
        }
    }

    // MARK: CSI

    private mutating func csi(_ byte: UInt8, _ handler: inout some TerminalHandler) {
        switch byte {
        case 0x1B:
            enterEscape()
        case 0x18, 0x1A: // CAN, SUB abort
            state = .ground
        case 0x00..<0x18, 0x19, 0x1C..<0x20:
            handler.executeControl(byte)
        case 0x30...0x39:
            if state == .csiIntermediate {
                state = .csiIgnore
            } else {
                state = .csiParam
                let digit = Int(byte - 0x30)
                currentParam = min((currentParam ?? 0) * 10 + digit, 65535)
            }
        case 0x3B, 0x3A: // ';' and ':' both split params in Phase 1
            if state == .csiIntermediate || params.count >= Self.maxParams {
                state = .csiIgnore
            } else {
                state = .csiParam
                params.append(currentParam ?? 0)
                currentParam = nil
            }
        case 0x3C...0x3F: // '<' '=' '>' '?'
            if state == .csiEntry {
                prefix = byte
                state = .csiParam
            } else {
                state = .csiIgnore
            }
        case 0x20...0x2F:
            if intermediates.count < 2 {
                intermediates.append(byte)
                state = .csiIntermediate
            } else {
                state = .csiIgnore
            }
        case 0x40...0x7E:
            if currentParam != nil || !params.isEmpty {
                params.append(currentParam ?? 0)
            }
            handler.csiDispatch(CSISequence(
                prefix: prefix, params: params, intermediates: intermediates, final: byte))
            state = .ground
        default: // 0x7F
            break
        }
    }

    private mutating func csiIgnore(_ byte: UInt8, _ handler: inout some TerminalHandler) {
        switch byte {
        case 0x1B:
            enterEscape()
        case 0x18, 0x1A:
            state = .ground
        case 0x00..<0x20:
            handler.executeControl(byte)
        case 0x40...0x7E:
            state = .ground
        default:
            break
        }
    }

    // MARK: Strings (OSC and discarded DCS/SOS/PM/APC)

    private mutating func oscString(_ byte: UInt8, _ handler: inout some TerminalHandler) {
        if stringEscape {
            stringEscape = false
            handler.oscDispatch(oscBuffer)
            oscBuffer = []
            if byte == 0x5C { // ESC \ = ST
                state = .ground
            } else {
                enterEscape()
                escape(byte, &handler)
            }
            return
        }
        switch byte {
        case 0x07: // BEL terminator
            handler.oscDispatch(oscBuffer)
            oscBuffer = []
            state = .ground
        case 0x1B:
            stringEscape = true
        case 0x18, 0x1A:
            oscBuffer = []
            state = .ground
        default:
            if oscBuffer.count < Self.maxOSCBytes {
                oscBuffer.append(byte)
            }
        }
    }

    private mutating func otherString(_ byte: UInt8, _ handler: inout some TerminalHandler) {
        if stringEscape {
            stringEscape = false
            if byte == 0x5C {
                state = .ground
            } else {
                enterEscape()
                escape(byte, &handler)
            }
            return
        }
        switch byte {
        case 0x1B:
            stringEscape = true
        case 0x18, 0x1A:
            state = .ground
        default:
            break
        }
    }
}
