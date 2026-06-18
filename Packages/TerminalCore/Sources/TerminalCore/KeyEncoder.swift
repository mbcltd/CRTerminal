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
/// The five flags of the [kitty spec](https://sw.kovidgoyal.net/kitty/keyboard-protocol/).
public struct KittyKeyboardFlags: OptionSet, Sendable, Equatable {
    public var rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue & 0b11111
    }

    /// 0b1 — escape and modified keys get unambiguous CSI u encodings.
    public static let disambiguate = KittyKeyboardFlags(rawValue: 1 << 0)
    /// 0b10 — append `:event-type` (press/repeat/release) to the encoded form.
    public static let reportEventTypes = KittyKeyboardFlags(rawValue: 1 << 1)
    /// 0b100 — append `:shifted-key:base-layout-key` alternate codepoints.
    public static let reportAlternateKeys = KittyKeyboardFlags(rawValue: 1 << 2)
    /// 0b1000 — report every key as an escape code (even plain text).
    public static let reportAllKeysAsEscapeCodes = KittyKeyboardFlags(rawValue: 1 << 3)
    /// 0b10000 — append the associated text codepoints as a trailing field.
    public static let reportAssociatedText = KittyKeyboardFlags(rawValue: 1 << 4)
}

/// Kitty key event type: the third sub-field of the modifier parameter.
public enum KeyEventType: Int, Sendable, Equatable {
    case press = 1
    case `repeat` = 2
    case release = 3
}

/// Pure (key, modifiers, modes) → bytes. The view translates NSEvents into
/// `TerminalKey`s; everything mode-dependent is decided here so the entire
/// matrix is unit-testable.
public enum KeyEncoder {
    public static func encode(
        _ key: TerminalKey,
        modifiers: KeyModifiers = [],
        applicationCursorKeys: Bool = false,
        kittyFlags: KittyKeyboardFlags = [],
        eventType: KeyEventType = .press
    ) -> [UInt8] {
        let allKeys = kittyFlags.contains(.reportAllKeysAsEscapeCodes)
        if kittyFlags.contains(.disambiguate) || allKeys {
            // Escape is the headline ambiguity CSI u resolves; Enter, Tab and
            // Backspace keep their legacy encodings at the disambiguate level
            // unless modified, but the all-keys level reports them too.
            switch key {
            case .escape:
                return csiU(27, modifiers, kittyFlags, eventType)
            case .enter where allKeys || !modifiers.isEmpty:
                return csiU(13, modifiers, kittyFlags, eventType)
            case .tab where modifiers == [.shift] && !allKeys:
                return bytes("\u{1B}[Z") // back-tab predates kitty; keep it
            case .tab where allKeys || !modifiers.isEmpty:
                return csiU(9, modifiers, kittyFlags, eventType)
            case .backspace where allKeys || !modifiers.isEmpty:
                return csiU(127, modifiers, kittyFlags, eventType)
            default:
                break
            }
        }
        switch key {
        case .up: return cursorKey("A", modifiers, applicationCursorKeys, kittyFlags, eventType)
        case .down: return cursorKey("B", modifiers, applicationCursorKeys, kittyFlags, eventType)
        case .right: return cursorKey("C", modifiers, applicationCursorKeys, kittyFlags, eventType)
        case .left: return cursorKey("D", modifiers, applicationCursorKeys, kittyFlags, eventType)
        case .home: return cursorKey("H", modifiers, applicationCursorKeys, kittyFlags, eventType)
        case .end: return cursorKey("F", modifiers, applicationCursorKeys, kittyFlags, eventType)
        case .pageUp: return tildeKey(5, modifiers, kittyFlags, eventType)
        case .pageDown: return tildeKey(6, modifiers, kittyFlags, eventType)
        case .deleteForward: return tildeKey(3, modifiers, kittyFlags, eventType)
        case .enter:
            // Alt/Option is Meta: Meta+Enter is the CR prefixed with ESC,
            // the legacy encoding apps (e.g. readline) expect to tell it
            // apart from a bare Return.
            return modifiers.contains(.option) ? [0x1B, 0x0D] : [0x0D]
        case .tab: return modifiers.contains(.shift) ? bytes("\u{1B}[Z") : [0x09]
        case .backspace: return [0x7F]
        case .escape: return [0x1B]
        case .function(let n): return functionKey(n, modifiers, kittyFlags, eventType)
        }
    }

    /// Character keys under the kitty protocol: returns the CSI u encoding when
    /// the protocol calls for one (a modified key while disambiguating, or any
    /// key once `reportAllKeysAsEscapeCodes` is on), nil when the caller should
    /// fall back to legacy bytes (plain text, ^C, ESC-prefix).
    ///
    /// `scalar` is the key's base (unshifted) codepoint. When `reportAlternateKeys`
    /// is set, `shiftedScalar` / `baseScalar` add the `:shifted:base` sub-fields;
    /// when `reportAssociatedText` is set, `text` adds the trailing text field.
    public static func encodeCharacter(
        _ scalar: Unicode.Scalar,
        modifiers: KeyModifiers,
        kittyFlags: KittyKeyboardFlags,
        eventType: KeyEventType = .press,
        shiftedScalar: Unicode.Scalar? = nil,
        baseScalar: Unicode.Scalar? = nil,
        text: String? = nil
    ) -> [UInt8]? {
        let modified = modifiers.contains(.control) || modifiers.contains(.option)
        guard kittyFlags.contains(.reportAllKeysAsEscapeCodes)
                || (kittyFlags.contains(.disambiguate) && modified)
        else { return nil }
        let shifted = shiftedScalar.map { Int($0.value) }
        let base = baseScalar.map { Int($0.value) }
        let textCodepoints = text.map { $0.unicodeScalars.map { Int($0.value) } } ?? []
        return csiU(
            Int(scalar.value), modifiers, kittyFlags, eventType,
            shifted: shifted, base: base, text: textCodepoints)
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

    /// Kitty CSI u: `ESC [ key ; modifiers ; text u`. The key field may carry
    /// `:shifted:base` alternates and the modifier field a `:event-type`; empty
    /// trailing fields are dropped so the simple cases stay compact (a bare
    /// `ESC [ code u`).
    private static func csiU(
        _ code: Int, _ modifiers: KeyModifiers, _ flags: KittyKeyboardFlags,
        _ eventType: KeyEventType, shifted: Int? = nil, base: Int? = nil, text: [Int] = []
    ) -> [UInt8] {
        var keyField = "\(code)"
        if flags.contains(.reportAlternateKeys), shifted != nil || base != nil {
            var subs = ["\(code)", shifted.map(String.init) ?? "", base.map(String.init) ?? ""]
            while subs.count > 1, subs.last == "" { subs.removeLast() }
            keyField = subs.joined(separator: ":")
        }
        let textField = flags.contains(.reportAssociatedText) && !text.isEmpty
            ? text.map(String.init).joined(separator: ":") : ""
        var fields = [keyField, modifierField(modifiers, flags, eventType), textField]
        while fields.count > 1, fields.last == "" { fields.removeLast() }
        return bytes("\u{1B}[\(fields.joined(separator: ";"))u")
    }

    /// The modifier parameter, with `:event-type` appended when event reporting
    /// is on. Empty (the field is omitted) when modifiers are default and event
    /// types aren't reported — keeping legacy output byte-identical.
    private static func modifierField(
        _ modifiers: KeyModifiers, _ flags: KittyKeyboardFlags, _ eventType: KeyEventType
    ) -> String {
        if flags.contains(.reportEventTypes) {
            return "\(modifiers.xtermParam):\(eventType.rawValue)"
        }
        return modifiers.xtermParam == 1 ? "" : "\(modifiers.xtermParam)"
    }

    private static func cursorKey(
        _ letter: Character, _ modifiers: KeyModifiers, _ application: Bool,
        _ flags: KittyKeyboardFlags, _ eventType: KeyEventType
    ) -> [UInt8] {
        let field = modifierField(modifiers, flags, eventType)
        if field.isEmpty {
            return application ? bytes("\u{1B}O\(letter)") : bytes("\u{1B}[\(letter)")
        }
        return bytes("\u{1B}[1;\(field)\(letter)")
    }

    private static func tildeKey(
        _ code: Int, _ modifiers: KeyModifiers,
        _ flags: KittyKeyboardFlags, _ eventType: KeyEventType
    ) -> [UInt8] {
        let field = modifierField(modifiers, flags, eventType)
        return field.isEmpty
            ? bytes("\u{1B}[\(code)~")
            : bytes("\u{1B}[\(code);\(field)~")
    }

    private static func functionKey(
        _ n: Int, _ modifiers: KeyModifiers,
        _ flags: KittyKeyboardFlags, _ eventType: KeyEventType
    ) -> [UInt8] {
        switch n {
        case 1...4:
            let letter = Character(Unicode.Scalar(UInt8(ascii: "P") + UInt8(n - 1)))
            let field = modifierField(modifiers, flags, eventType)
            if field.isEmpty {
                return bytes("\u{1B}O\(letter)")
            }
            return bytes("\u{1B}[1;\(field)\(letter)")
        case 5: return tildeKey(15, modifiers, flags, eventType)
        case 6...10: return tildeKey(17 + (n - 6), modifiers, flags, eventType) // 17,18,19,20,21
        case 11, 12: return tildeKey(23 + (n - 11), modifiers, flags, eventType)
        default: return []
        }
    }
}
