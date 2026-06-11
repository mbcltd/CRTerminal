import CoreGraphics
import CoreText
import Metal

/// Rasterizes glyphs with Core Text into an R8 texture atlas (shelf-packed).
/// Phase 1: grayscale only — color emoji get their own RGBA atlas in Phase 3.
final class GlyphAtlas {
    struct Entry {
        /// Normalized atlas coordinates.
        var uvOrigin: SIMD2<Float>
        var uvSize: SIMD2<Float>
        /// Quad size in pixels.
        var size: SIMD2<Float>
        /// Quad origin relative to (cell origin x, baseline y), pixels.
        var bearing: SIMD2<Float>
        /// Empty glyphs (spaces) rasterize to nothing.
        var isEmpty: Bool
    }

    private struct Key: Hashable {
        var fontIndex: UInt16
        var glyph: CGGlyph
    }

    let texture: MTLTexture
    /// Pixels per point; the atlas is rebuilt when the backing scale changes.
    let scale: CGFloat

    private static let textureSize = 2048
    private static let padding = 1

    private var fonts: [CTFont]
    private var entries: [Key: Entry] = [:]
    private var scalarToGlyph: [UInt32: (fontIndex: UInt16, glyph: CGGlyph)?] = [:]
    private var shelfX = 1
    private var shelfY = 1
    private var shelfHeight = 0

    init?(device: MTLDevice, font: CTFont, scale: CGFloat) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Self.textureSize,
            height: Self.textureSize,
            mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
        self.fonts = [font]
        self.scale = scale
    }

    func entry(forScalar scalar: UInt32) -> Entry? {
        guard let resolved = resolveGlyph(scalar) else { return nil }
        let key = Key(fontIndex: resolved.fontIndex, glyph: resolved.glyph)
        if let cached = entries[key] { return cached }
        let entry = rasterize(fonts[Int(resolved.fontIndex)], resolved.glyph)
        entries[key] = entry
        return entry
    }

    // MARK: Glyph resolution

    private func resolveGlyph(_ scalar: UInt32) -> (fontIndex: UInt16, glyph: CGGlyph)? {
        if let cached = scalarToGlyph[scalar] { return cached }
        let resolved = lookUpGlyph(scalar)
        scalarToGlyph[scalar] = resolved
        return resolved
    }

    private func lookUpGlyph(_ scalar: UInt32) -> (fontIndex: UInt16, glyph: CGGlyph)? {
        guard let unicodeScalar = Unicode.Scalar(scalar) else { return nil }
        var units = [UniChar]()
        for unit in String(unicodeScalar).utf16 { units.append(unit) }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)

        if CTFontGetGlyphsForCharacters(fonts[0], units, &glyphs, units.count), glyphs[0] != 0 {
            return (0, glyphs[0])
        }
        // Font fallback for symbols/CJK the primary font lacks.
        let string = String(unicodeScalar) as CFString
        let fallback = CTFontCreateForString(fonts[0], string, CFRange(location: 0, length: units.count))
        glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(fallback, units, &glyphs, units.count), glyphs[0] != 0 else {
            return nil
        }
        if let existing = fonts.firstIndex(where: { CFEqual($0, fallback) }) {
            return (UInt16(existing), glyphs[0])
        }
        fonts.append(fallback)
        return (UInt16(fonts.count - 1), glyphs[0])
    }

    // MARK: Rasterization

    private func rasterize(_ font: CTFont, _ glyph: CGGlyph) -> Entry {
        var glyph = glyph
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, &rect, 1)
        guard !rect.isEmpty else {
            return Entry(uvOrigin: .zero, uvSize: .zero, size: .zero, bearing: .zero, isEmpty: true)
        }

        let pad = Self.padding
        let width = Int((rect.width * scale).rounded(.up)) + 2 * pad
        let height = Int((rect.height * scale).rounded(.up)) + 2 * pad
        var pixels = [UInt8](repeating: 0, count: width * height)

        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            context.setShouldAntialias(true)
            context.setAllowsFontSmoothing(false)
            context.translateBy(
                x: CGFloat(pad) - rect.minX * scale,
                y: CGFloat(pad) - rect.minY * scale)
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(gray: 1, alpha: 1)
            var position = CGPoint.zero
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
        }

        guard let slot = allocate(width: width, height: height) else {
            // Atlas full: Phase 1 accepts a missing glyph; Phase 3 adds paging.
            return Entry(uvOrigin: .zero, uvSize: .zero, size: .zero, bearing: .zero, isEmpty: true)
        }
        // CGBitmapContext memory is top-row-first, matching atlas v-direction.
        texture.replace(
            region: MTLRegionMake2D(slot.x, slot.y, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width)

        let textureSize = Float(Self.textureSize)
        return Entry(
            uvOrigin: SIMD2(Float(slot.x) / textureSize, Float(slot.y) / textureSize),
            uvSize: SIMD2(Float(width) / textureSize, Float(height) / textureSize),
            size: SIMD2(Float(width), Float(height)),
            bearing: SIMD2(
                Float(rect.minX * scale) - Float(pad),
                Float(rect.maxY * scale) + Float(pad)),
            isEmpty: false)
    }

    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        let size = Self.textureSize
        guard width <= size else { return nil }
        if shelfX + width + 1 > size {
            shelfY += shelfHeight + 1
            shelfX = 1
            shelfHeight = 0
        }
        guard shelfY + height + 1 <= size else { return nil }
        let slot = (shelfX, shelfY)
        shelfX += width + 1
        shelfHeight = max(shelfHeight, height)
        return slot
    }
}
