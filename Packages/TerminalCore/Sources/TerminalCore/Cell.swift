/// A terminal color in 4 bytes: the default color, one of the 256 palette
/// entries, or a 24-bit RGB value. The tag lives in bits 24–25; the payload
/// in the low 24 bits.
public struct PackedColor: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    private enum Tag: UInt32 {
        case `default` = 0
        case palette = 1
        case rgb = 2
    }

    private var tag: UInt32 { rawValue >> 24 }

    public static let `default` = PackedColor(rawValue: 0)

    public static func palette(_ index: UInt8) -> PackedColor {
        PackedColor(rawValue: Tag.palette.rawValue << 24 | UInt32(index))
    }

    public static func rgb(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> PackedColor {
        PackedColor(rawValue: Tag.rgb.rawValue << 24 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue))
    }

    public var isDefault: Bool { tag == Tag.default.rawValue }

    public var paletteIndex: UInt8? {
        guard tag == Tag.palette.rawValue else { return nil }
        return UInt8(truncatingIfNeeded: rawValue)
    }

    public var rgb: (red: UInt8, green: UInt8, blue: UInt8)? {
        guard tag == Tag.rgb.rawValue else { return nil }
        return (
            UInt8(truncatingIfNeeded: rawValue >> 16),
            UInt8(truncatingIfNeeded: rawValue >> 8),
            UInt8(truncatingIfNeeded: rawValue)
        )
    }
}

/// SGR-style attributes plus structural flags for wide characters.
public struct CellAttributes: OptionSet, Hashable, Sendable {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let bold = CellAttributes(rawValue: 1 << 0)
    public static let faint = CellAttributes(rawValue: 1 << 1)
    public static let italic = CellAttributes(rawValue: 1 << 2)
    public static let underlined = CellAttributes(rawValue: 1 << 3)
    public static let blinking = CellAttributes(rawValue: 1 << 4)
    public static let inverse = CellAttributes(rawValue: 1 << 5)
    public static let hidden = CellAttributes(rawValue: 1 << 6)
    public static let struckThrough = CellAttributes(rawValue: 1 << 7)
    /// Head cell of a double-width character.
    public static let wide = CellAttributes(rawValue: 1 << 8)
    /// Spacer cell occupied by the right half of a double-width character.
    public static let wideSpacer = CellAttributes(rawValue: 1 << 9)
}

/// One screen cell. Kept inside a 16-byte stride so a full 4K screen of cells
/// stays cache-friendly; see ARCHITECTURE.md "Screen model".
public struct Cell: Hashable, Sendable {
    /// Unicode scalar value. Multi-scalar grapheme clusters will be stored in
    /// a per-screen side table and referenced here (Phase 2).
    public var glyph: UInt32
    public var foreground: PackedColor
    public var background: PackedColor
    public var attributes: CellAttributes
    /// OSC 8 hyperlink: 1-based index into `TerminalState.linkTable`,
    /// 0 = no link. Fills the cell's two spare bytes.
    public var link: UInt16

    public init(
        glyph: UInt32,
        foreground: PackedColor = .default,
        background: PackedColor = .default,
        attributes: CellAttributes = [],
        link: UInt16 = 0
    ) {
        self.glyph = glyph
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
        self.link = link
    }

    public static let blank = Cell(glyph: UInt32(UnicodeScalar(" ").value))
}

// MARK: - Codable (session restoration)
//
// `PackedColor` and `CellAttributes` are single-value wrappers over their
// raw integers; `Cell`'s conformance is synthesized from its stored fields.
// The snapshot codec packs cells as raw bytes (see `TerminalStateSnapshot`),
// but these conformances keep the types usable in any `Codable` container.

extension PackedColor: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt32.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension CellAttributes: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt16.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Cell: Codable {}
