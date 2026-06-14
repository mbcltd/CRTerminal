/// Sixel graphics, carried in a DCS string: `ESC P <P1>;<P2>;<P3> q <data> ESC \`.
/// The captured DCS payload still has the params and the `q` final byte in
/// front, so we strip those, then decode the sixel data to RGBA and place it
/// at the cursor like any other image.
///
/// Supported: palette select/define (RGB and HLS), repeat (`!`), carriage
/// return (`$`) and newline (`-`), raster attributes (`"`), and the P2=1
/// transparent-background flag.
extension TerminalState {
    public mutating func dcsDispatch(_ payload: [UInt8]) {
        // Leading numeric params, then the final byte (sixel = 'q').
        var i = 0
        var params: [Int] = []
        var current: Int?
        while i < payload.count {
            let b = payload[i]
            if b >= 0x30, b <= 0x39 {
                current = (current ?? 0) * 10 + Int(b - 0x30)
            } else if b == UInt8(ascii: ";") {
                params.append(current ?? 0)
                current = nil
            } else {
                break
            }
            i += 1
        }
        if let current { params.append(current) }
        guard i < payload.count, payload[i] == UInt8(ascii: "q") else { return }

        let transparent = params.count >= 2 && params[1] == 1
        guard let image = Self.decodeSixel(payload[(i + 1)...], transparent: transparent)
        else { return }
        let serial = storeImage(
            format: .rgba, pixelWidth: image.width, pixelHeight: image.height,
            bytes: image.pixels)
        displayImage(serial: serial)
    }

    private static let maxSixelDimension = 10_000

    /// Two passes: measure the canvas, then rasterize. Returns RGBA bytes.
    static func decodeSixel(
        _ data: ArraySlice<UInt8>, transparent: Bool
    ) -> (width: Int, height: Int, pixels: [UInt8])? {
        let bytes = Array(data)
        let measured = measureSixel(bytes)
        let width = min(measured.width, maxSixelDimension)
        let bands = measured.bands
        let height = min(bands * 6, maxSixelDimension)
        guard width > 0, height > 0, width * height <= maxImageBytes / 4 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var palette = defaultSixelPalette
        var color: (r: UInt8, g: UInt8, b: UInt8) = palette[0] ?? (0, 0, 0)
        var x = 0
        var band = 0
        var i = 0

        @inline(__always)
        func plot(_ sixel: UInt8, at px: Int, repeated count: Int) {
            guard px >= 0 else { return }
            let mask = Int(sixel) - 0x3F
            guard mask > 0 else { return }
            for rep in 0..<count {
                let col = px + rep
                guard col < width else { break }
                for row in 0..<6 where (mask & (1 << row)) != 0 {
                    let y = band * 6 + row
                    guard y < height else { continue }
                    let o = (y * width + col) * 4
                    pixels[o] = color.r
                    pixels[o + 1] = color.g
                    pixels[o + 2] = color.b
                    pixels[o + 3] = 255
                }
            }
        }

        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x3F...0x7E: // sixel data
                plot(b, at: x, repeated: 1)
                x += 1
                i += 1
            case UInt8(ascii: "!"): // RLE: !Pn<sixel>
                i += 1
                var count = 0
                while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                    count = count * 10 + Int(bytes[i] - 0x30); i += 1
                }
                count = max(1, count)
                if i < bytes.count, bytes[i] >= 0x3F, bytes[i] <= 0x7E {
                    plot(bytes[i], at: x, repeated: count)
                    x += count
                    i += 1
                }
            case UInt8(ascii: "#"): // color select / define
                i += 1
                var nums: [Int] = []
                var cur: Int?
                while i < bytes.count {
                    let c = bytes[i]
                    if c >= 0x30, c <= 0x39 { cur = (cur ?? 0) * 10 + Int(c - 0x30); i += 1 }
                    else if c == UInt8(ascii: ";") { nums.append(cur ?? 0); cur = nil; i += 1 }
                    else { break }
                }
                if let cur { nums.append(cur) }
                guard let index = nums.first else { break }
                if nums.count >= 5 {
                    let defined = sixelColor(system: nums[1], nums[2], nums[3], nums[4])
                    palette[index] = defined
                    color = defined
                } else {
                    color = palette[index] ?? (0, 0, 0)
                }
            case UInt8(ascii: "$"): // graphics CR
                x = 0
                i += 1
            case UInt8(ascii: "-"): // graphics NL
                band += 1
                x = 0
                i += 1
            case UInt8(ascii: "\""): // raster attributes: skip its params
                i += 1
                while i < bytes.count,
                      (bytes[i] >= 0x30 && bytes[i] <= 0x39) || bytes[i] == UInt8(ascii: ";") {
                    i += 1
                }
            default:
                i += 1
            }
        }
        return (width, height, pixels)
    }

    /// Cheap first pass: how wide and how many 6-px bands the data spans.
    private static func measureSixel(_ bytes: [UInt8]) -> (width: Int, bands: Int) {
        var rasterW = 0, rasterH = 0
        var x = 0, maxX = 0, band = 0
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x3F...0x7E:
                x += 1; maxX = max(maxX, x); i += 1
            case UInt8(ascii: "!"):
                i += 1
                var count = 0
                while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                    count = count * 10 + Int(bytes[i] - 0x30); i += 1
                }
                if i < bytes.count, bytes[i] >= 0x3F, bytes[i] <= 0x7E {
                    x += max(1, count); maxX = max(maxX, x); i += 1
                }
            case UInt8(ascii: "#"):
                i += 1
                while i < bytes.count,
                      (bytes[i] >= 0x30 && bytes[i] <= 0x39) || bytes[i] == UInt8(ascii: ";") {
                    i += 1
                }
            case UInt8(ascii: "$"):
                x = 0; i += 1
            case UInt8(ascii: "-"):
                band += 1; x = 0; i += 1
            case UInt8(ascii: "\""):
                i += 1
                var nums: [Int] = []
                var cur: Int?
                while i < bytes.count,
                      (bytes[i] >= 0x30 && bytes[i] <= 0x39) || bytes[i] == UInt8(ascii: ";") {
                    if bytes[i] == UInt8(ascii: ";") { nums.append(cur ?? 0); cur = nil }
                    else { cur = (cur ?? 0) * 10 + Int(bytes[i] - 0x30) }
                    i += 1
                }
                if let cur { nums.append(cur) }
                if nums.count >= 4 { rasterW = nums[2]; rasterH = nums[3] }
            default:
                i += 1
            }
        }
        let bandsFromData = band + 1
        let bands = rasterH > 0 ? max(bandsFromData, (rasterH + 5) / 6) : bandsFromData
        return (max(rasterW, maxX), bands)
    }

    /// Define a color from a `#` directive: system 2 = RGB, 1 = HLS, each
    /// component 0…100 (HLS hue 0…360).
    private static func sixelColor(
        system: Int, _ a: Int, _ b: Int, _ c: Int
    ) -> (r: UInt8, g: UInt8, b: UInt8) {
        func scale(_ v: Int) -> UInt8 { UInt8(min(max(v, 0), 100) * 255 / 100) }
        if system == 1 { // HLS
            return hlsToRGB(hue: a, lightness: b, saturation: c)
        }
        return (scale(a), scale(b), scale(c)) // RGB (system 2, and as fallback)
    }

    private static func hlsToRGB(
        hue: Int, lightness: Int, saturation: Int
    ) -> (r: UInt8, g: UInt8, b: UInt8) {
        let h = Double((hue % 360 + 360) % 360) / 360
        let l = Double(min(max(lightness, 0), 100)) / 100
        let s = Double(min(max(saturation, 0), 100)) / 100
        guard s > 0 else { let v = UInt8(l * 255); return (v, v, v) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> UInt8 {
            var t = t0
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            let value: Double
            if t < 1.0 / 6 { value = p + (q - p) * 6 * t }
            else if t < 1.0 / 2 { value = q }
            else if t < 2.0 / 3 { value = p + (q - p) * (2.0 / 3 - t) * 6 }
            else { value = p }
            return UInt8(min(max(value, 0), 1) * 255)
        }
        // DEC HLS places hue 0 at blue; rotate to the usual red-at-0 wheel.
        return (channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }

    /// VT340 default 16-color sixel palette (RGB, already 0…255).
    private static let defaultSixelPalette: [Int: (r: UInt8, g: UInt8, b: UInt8)] = [
        0: (0, 0, 0), 1: (51, 51, 204), 2: (204, 36, 36), 3: (51, 204, 51),
        4: (204, 51, 204), 5: (51, 204, 204), 6: (204, 204, 51), 7: (135, 135, 135),
        8: (66, 66, 66), 9: (84, 84, 153), 10: (153, 66, 66), 11: (66, 153, 66),
        12: (153, 66, 153), 13: (66, 153, 153), 14: (153, 153, 66), 15: (204, 204, 204),
    ]
}
