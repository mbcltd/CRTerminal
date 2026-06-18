/// Runtime color overrides applied on top of the preset's palette by OSC 4 /
/// 10 / 11 / 12. The renderer consults these before the preset colors; reset
/// sequences clear them. Sparse: only slots a program has actually set appear,
/// so an untouched terminal carries no override state at all (issue #25).
public struct ColorOverrides: Sendable {
    /// Palette slot (0–255) → RGB, for OSC 4.
    public var palette: [UInt8: (red: UInt8, green: UInt8, blue: UInt8)] = [:]
    /// Default foreground / background / cursor, for OSC 10 / 11 / 12.
    public var foreground: (red: UInt8, green: UInt8, blue: UInt8)?
    public var background: (red: UInt8, green: UInt8, blue: UInt8)?
    public var cursor: (red: UInt8, green: UInt8, blue: UInt8)?

    public init() {}

    /// True when nothing is overridden — the renderer's per-frame fast path.
    public var isEmpty: Bool {
        palette.isEmpty && foreground == nil && background == nil && cursor == nil
    }
}

extension TerminalState {
    /// The standard xterm 256-color palette value for a slot, used to answer an
    /// `OSC 4;n;?` query for a slot the program hasn't overridden. This mirrors
    /// the renderer's `xterm256()` table (CRTRendering owns the colors a preset
    /// actually paints with, but TerminalCore is platform-independent and can't
    /// import it); a preset's custom ANSI hues aren't reflected here, matching
    /// xterm's behaviour of reporting the base palette for un-set slots.
    static func defaultPaletteColor(_ index: UInt8) -> (red: UInt8, green: UInt8, blue: UInt8) {
        switch index {
        case 0..<16:
            let ansi: [(UInt8, UInt8, UInt8)] = [
                (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
                (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
                (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
                (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
            ]
            return ansi[Int(index)]
        case 16..<232:
            let n = Int(index) - 16
            let level: [UInt8] = [0, 95, 135, 175, 215, 255]
            return (level[n / 36], level[(n / 6) % 6], level[n % 6])
        default:
            let v = UInt8(8 + 10 * (Int(index) - 232))
            return (v, v, v)
        }
    }

    /// Parse an xterm color spec into 8-bit RGB. Accepts the common forms:
    /// `rgb:RR/GG/BB` and `rgb:RRRR/GGGG/BBBB` (1–4 hex digits per channel,
    /// scaled to 8 bits), `#RGB` / `#RRGGBB` / `#RRRRGGGGBBBB`, and a minimal set
    /// of X11 color names. Returns nil for anything malformed, so a bad spec
    /// leaves state untouched rather than trapping.
    static func parseColorSpec(_ spec: ArraySlice<UInt8>) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        let text = String(decoding: spec, as: UTF8.self)
        if text.hasPrefix("rgb:") {
            return parseRGBSpec(text.dropFirst(4))
        }
        if text.hasPrefix("#") {
            return parseHashSpec(text.dropFirst())
        }
        return namedColors[text.lowercased()]
    }

    /// `rgb:` body: three `/`-separated channels of 1–4 hex digits each.
    private static func parseRGBSpec(_ body: Substring) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        let parts = body.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let r = scaledChannel(parts[0]),
              let g = scaledChannel(parts[1]),
              let b = scaledChannel(parts[2]) else { return nil }
        return (r, g, b)
    }

    /// `#` body: 3, 6, or 12 hex digits (equal-width channels).
    private static func parseHashSpec(_ body: Substring) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        guard body.count % 3 == 0, !body.isEmpty else { return nil }
        let width = body.count / 3
        guard width <= 4 else { return nil }
        let digits = Array(body)
        func channel(_ i: Int) -> UInt8? {
            scaledChannel(Substring(String(digits[i * width ..< (i + 1) * width])))
        }
        guard let r = channel(0), let g = channel(1), let b = channel(2) else { return nil }
        return (r, g, b)
    }

    /// Parse 1–4 hex digits and scale to an 8-bit channel (`ff`→255, `ffff`→255,
    /// `0`→0), matching xterm's full-range scaling so values round-trip.
    private static func scaledChannel(_ digits: Substring) -> UInt8? {
        guard (1...4).contains(digits.count),
              let value = UInt32(digits, radix: 16) else { return nil }
        let maxValue = (UInt32(1) << (4 * digits.count)) - 1
        return UInt8(value * 255 / maxValue)
    }

    /// A minimal X11 color-name table — the eight ANSI primaries plus the most
    /// common neutrals, which is what tools that pass names by string actually
    /// use. Unknown names fall through to nil (the set is ignored).
    private static let namedColors: [String: (red: UInt8, green: UInt8, blue: UInt8)] = [
        "black": (0, 0, 0), "red": (255, 0, 0), "green": (0, 128, 0),
        "yellow": (255, 255, 0), "blue": (0, 0, 255), "magenta": (255, 0, 255),
        "cyan": (0, 255, 255), "white": (255, 255, 255), "gray": (190, 190, 190),
        "grey": (190, 190, 190),
    ]
}
