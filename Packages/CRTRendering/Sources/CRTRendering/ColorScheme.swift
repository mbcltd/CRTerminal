import TerminalCore

/// Resolves terminal colors to packed 0xRRGGBBAA values for the GPU.
public struct ColorScheme: Sendable {
    public var foreground: UInt32
    public var background: UInt32
    public var selectionBackground: UInt32
    public var palette: [UInt32] // 256 entries
    /// The block/bar/underline cursor fill. Defaults to `foreground` (xterm's
    /// behaviour); OSC 12 overrides it via `applyingOverrides`.
    public var cursorColor: UInt32
    /// Find-bar highlight for *every* match in the buffer (dim); the current
    /// match is emphasized with `searchCurrentMatchBackground` instead.
    public var searchMatchBackground: UInt32
    /// Find-bar highlight for the *current* match (bright — bloom turns it into
    /// the glow the mockup calls for under CRT presets).
    public var searchCurrentMatchBackground: UInt32

    public init(
        foreground: UInt32, background: UInt32,
        selectionBackground: UInt32, palette: [UInt32]
    ) {
        precondition(palette.count == 256)
        self.foreground = foreground
        self.background = background
        self.selectionBackground = selectionBackground
        self.palette = palette
        self.cursorColor = foreground
        // Warm amber highlights, tuned per background luma so the cell's
        // existing foreground stays legible over them.
        let (match, current) = Self.defaultSearchHighlights(
            backgroundIsLight: Self.isLight(background))
        self.searchMatchBackground = match
        self.searchCurrentMatchBackground = current
    }

    /// Light gray on near-black with the standard xterm 256-color palette.
    public static let `default` = ColorScheme(
        foreground: pack(0xD8, 0xD8, 0xD8),
        background: pack(0x0D, 0x12, 0x0E),
        selectionBackground: pack(0x33, 0x4E, 0x6E),
        palette: xterm256())

    /// Near-black on paper white: the light counterpart of `default`,
    /// sharing the standard xterm 256-color palette.
    public static let light = ColorScheme(
        foreground: pack(0x1C, 0x1C, 0x1C),
        background: pack(0xF7, 0xF6, 0xF2),
        selectionBackground: pack(0xB3, 0xD4, 0xFF),
        palette: xterm256())

    /// A scheme from an explicit preset palette: the standard xterm 256-color
    /// table with the 16 ANSI slots overridden by whichever hues the palette
    /// specifies, plus its own foreground, background and selection.
    public init(palette: CRTPreset.Palette) {
        var colors = Self.xterm256()
        let ansi: [HexColor?] = [
            palette.black, palette.red, palette.green, palette.yellow,
            palette.blue, palette.magenta, palette.cyan, palette.white,
            palette.brightBlack, palette.brightRed, palette.brightGreen, palette.brightYellow,
            palette.brightBlue, palette.brightMagenta, palette.brightCyan, palette.brightWhite,
        ]
        for (index, hex) in ansi.enumerated() {
            if let hex { colors[index] = Self.pack(hex.red, hex.green, hex.blue) }
        }
        let fg = palette.foreground, bg = palette.background
        let selection = palette.selection
        self.init(
            foreground: Self.pack(fg.red, fg.green, fg.blue),
            background: Self.pack(bg.red, bg.green, bg.blue),
            selectionBackground: selection.map { Self.pack($0.red, $0.green, $0.blue) }
                ?? Self.pack(0x33, 0x4E, 0x6E),
            palette: colors)
    }

    /// The terminal scheme a preset paints with: an explicit palette wins;
    /// otherwise `appearance` picks the light scheme or `darkBase` (the
    /// renderer's configured dark scheme). Shared by the renderer's per-frame
    /// resolution and the app's OSC 10/11 color reporting so both agree.
    public static func resolve(
        for preset: CRTPreset, darkBase: ColorScheme = .default
    ) -> ColorScheme {
        if let palette = preset.colors { return ColorScheme(palette: palette) }
        return preset.appearance == .light ? .light : darkBase
    }

    /// The foreground/background as 8-bit RGB triples (dropping the alpha the
    /// packed form carries), for callers reporting colors outside the GPU —
    /// e.g. the terminal's OSC 10/11 color queries.
    public var foregroundRGB: (red: UInt8, green: UInt8, blue: UInt8) { Self.unpack(foreground) }
    public var backgroundRGB: (red: UInt8, green: UInt8, blue: UInt8) { Self.unpack(background) }

    /// Whether the background reads as light (Rec. 601 luma over half), the
    /// authoritative signal for the COLORFGBG light/dark hint regardless of how
    /// the scheme was derived (appearance flag or a custom palette's hue).
    public var isLightBackground: Bool { Self.isLight(background) }

    /// Rec. 601 luma test on a packed color — over half reads as light.
    private static func isLight(_ packed: UInt32) -> Bool {
        let r = Double((packed >> 24) & 0xFF)
        let g = Double((packed >> 16) & 0xFF)
        let b = Double((packed >> 8) & 0xFF)
        return 0.299 * r + 0.587 * g + 0.114 * b > 127.5
    }

    /// The dim/current find-match fills for a given background. Dark schemes
    /// get deep amber so light text stays readable; light schemes get a pale
    /// yellow → orange pair that dark text reads cleanly over.
    private static func defaultSearchHighlights(
        backgroundIsLight: Bool
    ) -> (match: UInt32, current: UInt32) {
        backgroundIsLight
            ? (pack(0xFF, 0xE0, 0x8A), pack(0xFF, 0xA5, 0x33))
            : (pack(0x4A, 0x3A, 0x0E), pack(0x9C, 0x6A, 0x12))
    }

    private static func unpack(_ c: UInt32) -> (red: UInt8, green: UInt8, blue: UInt8) {
        (UInt8((c >> 24) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF))
    }

    public func resolve(_ color: PackedColor, isForeground: Bool, bold: Bool) -> UInt32 {
        if color.isDefault {
            return isForeground ? foreground : background
        }
        if var index = color.paletteIndex {
            if bold && isForeground && index < 8 { index += 8 }
            return palette[Int(index)]
        }
        if let rgb = color.rgb {
            return Self.pack(rgb.red, rgb.green, rgb.blue)
        }
        return isForeground ? foreground : background
    }

    /// This scheme with the terminal's runtime OSC color overrides layered on
    /// top: palette slots (OSC 4), foreground / background (OSC 10/11), and the
    /// cursor (OSC 12). Returns `self` unchanged when nothing is overridden —
    /// the common per-frame fast path (issue #25).
    public func applyingOverrides(_ overrides: ColorOverrides) -> ColorScheme {
        guard !overrides.isEmpty else { return self }
        var scheme = self
        for (index, c) in overrides.palette {
            scheme.palette[Int(index)] = Self.pack(c.red, c.green, c.blue)
        }
        if let fg = overrides.foreground { scheme.foreground = Self.pack(fg.red, fg.green, fg.blue) }
        if let bg = overrides.background { scheme.background = Self.pack(bg.red, bg.green, bg.blue) }
        scheme.cursorColor = overrides.cursor
            .map { Self.pack($0.red, $0.green, $0.blue) } ?? scheme.foreground
        return scheme
    }

    public static func pack(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> UInt32 {
        UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a)
    }

    private static func xterm256() -> [UInt32] {
        var colors = [UInt32]()
        colors.reserveCapacity(256)
        // 16 ANSI colors, xterm defaults.
        let ansi: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
            (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
            (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
            (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
        ]
        for (r, g, b) in ansi {
            colors.append(pack(r, g, b))
        }
        // 6×6×6 cube.
        let level: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    colors.append(pack(level[r], level[g], level[b]))
                }
            }
        }
        // Grayscale ramp.
        for i in 0..<24 {
            let v = UInt8(8 + 10 * i)
            colors.append(pack(v, v, v))
        }
        return colors
    }
}
