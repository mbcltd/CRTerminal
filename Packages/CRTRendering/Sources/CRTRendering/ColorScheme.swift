import TerminalCore

/// Resolves terminal colors to packed 0xRRGGBBAA values for the GPU.
public struct ColorScheme: Sendable {
    public var foreground: UInt32
    public var background: UInt32
    public var palette: [UInt32] // 256 entries

    public init(foreground: UInt32, background: UInt32, palette: [UInt32]) {
        precondition(palette.count == 256)
        self.foreground = foreground
        self.background = background
        self.palette = palette
    }

    /// Light gray on near-black with the standard xterm 256-color palette.
    public static let `default` = ColorScheme(
        foreground: pack(0xD8, 0xD8, 0xD8),
        background: pack(0x0D, 0x12, 0x0E),
        palette: xterm256())

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
