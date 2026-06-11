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

/// Kitty keyboard protocol progressive-enhancement flags (CSI > flags u).
public struct KittyKeyboardFlags: OptionSet, Sendable, Equatable {
    public var rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue & 0b11111
    }

    /// Flag 1: escape and modified keys get unambiguous CSI u encodings.
    public static let disambiguate = KittyKeyboardFlags(rawValue: 1 << 0)
    // Flags 2–16 (event types, alternate keys, all-keys-as-escapes,
    // associated text) are accepted on the wire but not yet honored.
}

/// Pure (key, modifiers, modes) → bytes. The view translates NSEvents into
/// `TerminalKey`s; everything mode-dependent is decided here so the entire
/// matrix is unit-testable.
public enum KeyEncoder {
    public static func encode(
        _ key: TerminalKey,
        modifiers: KeyModifiers = [],
        applicationCursorKeys: Bool = false,
        kittyFlags: KittyKeyboardFlags = []
    ) -> [UInt8] {
        if kittyFlags.contains(.disambiguate) {
            // Escape is the headline ambiguity CSI u resolves; Enter, Tab
            // and Backspace keep their legacy encodings at this level
            // unless modified.
            switch key {
            case .escape:
                return csiU(27, modifiers)
            case .enter where !modifiers.isEmpty:
                return csiU(13, modifiers)
            case .tab where modifiers == [.shift]:
                return bytes("\u{1B}[Z") // back-tab predates kitty; keep it
            case .tab where !modifiers.isEmpty:
                return csiU(9, modifiers)
            case .backspace where !modifiers.isEmpty:
                return csiU(127, modifiers)
            default:
                break
            }
        }
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

    /// Character keys with modifiers under the kitty protocol: returns the
    /// CSI u encoding when disambiguation calls for one, nil when the
    /// caller should fall back to legacy bytes (plain text, ^C, ESC-prefix).
    public static func encodeCharacter(
        _ scalar: Unicode.Scalar,
        modifiers: KeyModifiers,
        kittyFlags: KittyKeyboardFlags
    ) -> [UInt8]? {
        guard kittyFlags.contains(.disambiguate),
              modifiers.contains(.control) || modifiers.contains(.option)
        else { return nil }
        return csiU(Int(scalar.value), modifiers)
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

    /// Kitty CSI u: `ESC [ code ; modifiers u` (modifier param omitted when 1).
    private static func csiU(_ code: Int, _ modifiers: KeyModifiers) -> [UInt8] {
        modifiers.isEmpty
            ? bytes("\u{1B}[\(code)u")
            : bytes("\u{1B}[\(code);\(modifiers.xtermParam)u")
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
