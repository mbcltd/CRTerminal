public enum MouseButton: Int, Sendable {
    case left = 0
    case middle = 1
    case right = 2
    case none = 3
    case wheelUp = 64
    case wheelDown = 65
    case wheelLeft = 66
    case wheelRight = 67
}

public enum MouseEventKind: Sendable {
    case press
    case release
    case drag
    case motion
}

/// Pure mouse-protocol encoding. The view decides *which* events to send
/// (per `TerminalModes.mouseMode`); this encodes them. Coordinates are
/// 0-based cells; `pixelX`/`pixelY` are 0-based device-pixel positions used
/// only by the `.sgrPixels` (DEC ?1016) encoding.
public enum MouseEncoder {
    public static func encode(
        _ kind: MouseEventKind,
        button: MouseButton,
        x: Int,
        y: Int,
        pixelX: Int = 0,
        pixelY: Int = 0,
        modifiers: KeyModifiers = [],
        encoding: MouseEncoding
    ) -> [UInt8] {
        var code = kind == .motion && button == .none ? 3 : button.rawValue
        if kind == .drag || kind == .motion { code += 32 }
        if modifiers.contains(.shift) { code += 4 }
        if modifiers.contains(.option) { code += 8 }
        if modifiers.contains(.control) { code += 16 }

        switch encoding {
        case .sgr:
            let final = kind == .release ? "m" : "M"
            return Array("\u{1B}[<\(code);\(x + 1);\(y + 1)\(final)".utf8)
        case .sgrPixels:
            // Like SGR, but X/Y are 1-based pixel coordinates (DEC ?1016).
            let final = kind == .release ? "m" : "M"
            return Array("\u{1B}[<\(code);\(pixelX + 1);\(pixelY + 1)\(final)".utf8)
        case .legacy:
            if kind == .release { code = (code & ~3) | 3 }
            // Coordinates clamp at 223 (255 - 32) in the legacy encoding.
            let cx = UInt8(min(x + 1, 223) + 32)
            let cy = UInt8(min(y + 1, 223) + 32)
            return [0x1B, UInt8(ascii: "["), UInt8(ascii: "M"), UInt8(32 + min(code, 223)), cx, cy]
        }
    }
}
