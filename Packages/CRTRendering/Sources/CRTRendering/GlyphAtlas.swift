import CoreGraphics
import CoreText
import Metal

/// Rasterizes glyphs with Core Text into texture atlases (shelf-packed):
/// an R8 atlas for grayscale glyphs and a BGRA atlas for color (emoji)
/// glyphs, detected via the font's color-glyphs trait.
final class GlyphAtlas {
    struct Entry {
        /// Normalized atlas coordinates.
        var uvOrigin: SIMD2<Float>
        var uvSize: SIMD2<Float>
        /// Quad size in pixels.
        var size: SIMD2<Float>
        /// Quad origin relative to (cell origin x, baseline y), pixels.
        var bearing: SIMD2<Float>
        /// Sampled from the color atlas (premultiplied BGRA) instead of R8.
        var isColor: Bool
        /// Empty glyphs (spaces) rasterize to nothing.
        var isEmpty: Bool

        static let empty = Entry(
            uvOrigin: .zero, uvSize: .zero, size: .zero, bearing: .zero,
            isColor: false, isEmpty: true)
    }

    private struct Key: Hashable {
        var fontIndex: UInt16
        var glyph: CGGlyph
    }

    private struct ShelfPacker {
        let size: Int
        private var x = 1
        private var y = 1
        private var rowHeight = 0

        init(size: Int) {
            self.size = size
        }

        mutating func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
            guard width <= size else { return nil }
            if x + width + 1 > size {
                y += rowHeight + 1
                x = 1
                rowHeight = 0
            }
            guard y + height + 1 <= size else { return nil }
            let slot = (x, y)
            x += width + 1
            rowHeight = max(rowHeight, height)
            return slot
        }
    }

    let texture: MTLTexture       // r8Unorm, grayscale coverage
    let colorTexture: MTLTexture  // bgra8Unorm, premultiplied color glyphs
    /// Pixels per point; the atlas is rebuilt when the backing scale changes.
    let scale: CGFloat

    private static let textureSize = 2048

    private var fonts: [CTFont]
    private var entries: [Key: Entry] = [:]
    private var scalarToGlyph: [UInt32: (fontIndex: UInt16, glyph: CGGlyph)?] = [:]
    private var grayPacker = ShelfPacker(size: textureSize)
    private var colorPacker = ShelfPacker(size: textureSize)

    init?(device: MTLDevice, font: CTFont, scale: CGFloat) {
        let grayDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Self.textureSize,
            height: Self.textureSize,
            mipmapped: false)
        grayDescriptor.usage = [.shaderRead]
        grayDescriptor.storageMode = .shared
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Self.textureSize,
            height: Self.textureSize,
            mipmapped: false)
        colorDescriptor.usage = [.shaderRead]
        colorDescriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: grayDescriptor),
              let colorTexture = device.makeTexture(descriptor: colorDescriptor)
        else { return nil }
        self.texture = texture
        self.colorTexture = colorTexture
        self.fonts = [font]
        self.scale = scale
    }

    func entry(forScalar scalar: UInt32) -> Entry? {
        guard let resolved = resolveGlyph(scalar) else { return nil }
        let key = Key(fontIndex: resolved.fontIndex, glyph: resolved.glyph)
        if let cached = entries[key] { return cached }
        let font = fonts[Int(resolved.fontIndex)]
        let isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        let entry = rasterize(font, resolved.glyph, color: isColor)
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
        // Font fallback for symbols/CJK/emoji the primary font lacks.
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

    private func rasterize(_ font: CTFont, _ glyph: CGGlyph, color: Bool) -> Entry {
        var glyph = glyph
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, &rect, 1)
        guard !rect.isEmpty else { return .empty }

        let pad = 1
        let width = Int((rect.width * scale).rounded(.up)) + 2 * pad
        let height = Int((rect.height * scale).rounded(.up)) + 2 * pad
        let bytesPerPixel = color ? 4 : 1
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        pixels.withUnsafeMutableBytes { buffer in
            let context: CGContext?
            if color {
                context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                        | CGImageAlphaInfo.premultipliedFirst.rawValue)
            } else {
                context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            }
            guard let context else { return }
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

        let slot: (x: Int, y: Int)?
        if color {
            slot = colorPacker.allocate(width: width, height: height)
        } else {
            slot = grayPacker.allocate(width: width, height: height)
        }
        guard let slot else {
            // Atlas full: Phase 1 accepts a missing glyph; paging comes later.
            return .empty
        }
        // CGBitmapContext memory is top-row-first, matching atlas v-direction.
        (color ? colorTexture : texture).replace(
            region: MTLRegionMake2D(slot.x, slot.y, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * bytesPerPixel)

        let textureSize = Float(Self.textureSize)
        return Entry(
            uvOrigin: SIMD2(Float(slot.x) / textureSize, Float(slot.y) / textureSize),
            uvSize: SIMD2(Float(width) / textureSize, Float(height) / textureSize),
            size: SIMD2(Float(width), Float(height)),
            bearing: SIMD2(
                Float(rect.minX * scale) - Float(pad),
                Float(rect.maxY * scale) + Float(pad)),
            isColor: color,
            isEmpty: false)
    }
}
