public enum TerminalKey: Sendable, Equatable {
    case up, down, left, right
    case home, end, pageUp, pageDown
    case enter, tab, backspace, escape, deleteForward
    case function(Int) // F1–F12
}

public struct KeyModifiers: OptionSet, Sendable {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)

    /// xterm modifier parameter: 1 + (shift=1, alt=2, ctrl=4).
    var xtermParam: Int {
        1 + Int(rawValue & 1) + Int(rawValue & 2) + Int(rawValue & 4)
    }
}

/// Pure (key, modifiers, modes) → bytes. The view translates NSEvents into
/// `TerminalKey`s; everything mode-dependent is decided here so the entire
/// matrix is unit-testable.
public enum KeyEncoder {
    public static func encode(
        _ key: TerminalKey,
        modifiers: KeyModifiers = [],
        applicationCursorKeys: Bool = false
    ) -> [UInt8] {
        switch key {
        case .up: return cursorKey("A", modifiers, applicationCursorKeys)
        case .down: return cursorKey("B", modifiers, applicationCursorKeys)
        case .right: return cursorKey("C", modifiers, applicationCursorKeys)
        case .left: return cursorKey("D", modifiers, applicationCursorKeys)
        case .home: return cursorKey("H", modifiers, applicationCursorKeys)
        case .end: return cursorKey("F", modifiers, applicationCursorKeys)
        case .pageUp: return tildeKey(5, modifiers)
        case .pageDown: return tildeKey(6, modifiers)
        case .deleteForward: return tildeKey(3, modifiers)
        case .enter: return [0x0D]
        case .tab: return modifiers.contains(.shift) ? bytes("\u{1B}[Z") : [0x09]
        case .backspace: return [0x7F]
        case .escape: return [0x1B]
        case .function(let n): return functionKey(n, modifiers)
        }
    }

    /// Control-key combination, e.g. ^C. Returns nil if the character has no
    /// control mapping.
    public static func encodeControl(_ character: Character) -> UInt8? {
        guard let ascii = character.uppercased().first?.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "@")...UInt8(ascii: "_"):
            return ascii & 0x1F
        case UInt8(ascii: "?"):
            return 0x7F
        case UInt8(ascii: " "):
            return 0x00
        default:
            return nil
        }
    }

    public static func encodePaste(_ text: String, bracketed: Bool) -> [UInt8] {
        var out: [UInt8] = []
        if bracketed { out += bytes("\u{1B}[200~") }
        // Normalize line endings to CR, as a keyboard would produce.
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                if previous != 0x0D { out.append(0x0D) }
            } else {
                out.append(byte)
            }
            previous = byte
        }
        if bracketed { out += bytes("\u{1B}[201~") }
        return out
    }

    // MARK: Helpers

    private static func bytes(_ s: String) -> [UInt8] {
        Array(s.utf8)
    }

    private static func cursorKey(
        _ letter: Character, _ modifiers: KeyModifiers, _ application: Bool
    ) -> [UInt8] {
        if modifiers.isEmpty {
            return application ? bytes("\u{1B}O\(letter)") : bytes("\u{1B}[\(letter)")
        }
        return bytes("\u{1B}[1;\(modifiers.xtermParam)\(letter)")
    }

    private static func tildeKey(_ code: Int, _ modifiers: KeyModifiers) -> [UInt8] {
        if modifiers.isEmpty {
            return bytes("\u{1B}[\(code)~")
        }
        return bytes("\u{1B}[\(code);\(modifiers.xtermParam)~")
    }

    private static func functionKey(_ n: Int, _ modifiers: KeyModifiers) -> [UInt8] {
        switch n {
        case 1...4:
            let letter = Character(Unicode.Scalar(UInt8(ascii: "P") + UInt8(n - 1)))
            if modifiers.isEmpty {
                return bytes("\u{1B}O\(letter)")
            }
            return bytes("\u{1B}[1;\(modifiers.xtermParam)\(letter)")
        case 5: return tildeKey(15, modifiers)
        case 6...10: return tildeKey(17 + (n - 6), modifiers) // 17,18,19,20,21
        case 11, 12: return tildeKey(23 + (n - 11), modifiers)
        default: return []
        }
    }
}
