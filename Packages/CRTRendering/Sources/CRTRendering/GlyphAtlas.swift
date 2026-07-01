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
    private var boxEntries: [UInt32: Entry] = [:]
    private var grayPacker = ShelfPacker(size: textureSize)
    private var colorPacker = ShelfPacker(size: textureSize)

    /// Cell extent in device pixels and the baseline's distance below the
    /// cell top — needed to synthesize exact-cell box/block glyphs.
    private let cellWidthPx: Int
    private let cellHeightPx: Int
    private let ascentPx: Float

    init?(device: MTLDevice, font: CTFont, scale: CGFloat,
          cellSize: CGSize, ascent: CGFloat) {
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
        self.cellWidthPx = Int((cellSize.width * scale).rounded())
        self.cellHeightPx = Int((cellSize.height * scale).rounded())
        self.ascentPx = Float(ascent * scale)
    }

    // MARK: Ligature shaping

    /// One glyph of a shaped run: a primary-font glyph id plus its x
    /// offset from the run origin in device pixels.
    struct ShapedGlyph: Equatable {
        var glyph: CGGlyph
        var xOffsetPx: Float
    }

    /// Shaped runs by source text. Entries are nil when shaping bailed
    /// (fallback font crept in); the bail is cached too.
    private var shapeCache: [String: [ShapedGlyph]?] = [:]
    private static let shapeCacheLimit = 4096

    /// The primary font with every ligature feature selector switched
    /// on. Coding fonts often park their arrows in a stylistic set
    /// (Geist Mono calls it "Coding ligatures") that default shaping
    /// ignores; same glyph ids, so atlas rasterization is unaffected.
    private lazy var shapingFont: CTFont = Self.ligatureFont(for: fonts[0])

    static func ligatureFont(for font: CTFont) -> CTFont {
        guard let features = CTFontCopyFeatures(font) as? [[String: Any]] else {
            return font
        }
        var settings: [[CFString: Any]] = []
        for feature in features {
            guard let type = feature[kCTFontFeatureTypeIdentifierKey as String]
            else { continue }
            let selectors = feature[kCTFontFeatureTypeSelectorsKey as String]
                as? [[String: Any]] ?? []
            for selector in selectors {
                guard let name = selector[kCTFontFeatureSelectorNameKey as String]
                        as? String,
                      name.localizedCaseInsensitiveContains("ligature"),
                      !name.localizedCaseInsensitiveContains("off"),
                      let id = selector[kCTFontFeatureSelectorIdentifierKey as String]
                else { continue }
                settings.append([
                    kCTFontFeatureTypeIdentifierKey: type,
                    kCTFontFeatureSelectorIdentifierKey: id,
                ])
            }
        }
        guard !settings.isEmpty else { return font }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFeatureSettingsAttribute: settings as CFArray,
        ] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, 0, nil, descriptor)
    }

    /// Shapes a run of text with Core Text so contextual ligatures
    /// (=>, ===, //) substitute. Returns nil when the result cannot be
    /// trusted to the primary font — the caller falls back per-cell.
    func shape(_ text: String) -> [ShapedGlyph]? {
        if let cached = shapeCache[text] { return cached }
        let shaped = shapeUncached(text)
        if shapeCache.count >= Self.shapeCacheLimit {
            shapeCache.removeAll(keepingCapacity: true)
        }
        shapeCache[text] = shaped
        return shaped
    }

    private func shapeUncached(_ text: String) -> [ShapedGlyph]? {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: shapingFont,
            kCTLigatureAttributeName: 1 as CFNumber,
        ]
        guard let attributed = CFAttributedStringCreate(
            nil, text as CFString, attributes as CFDictionary)
        else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun],
              runs.count == 1, let run = runs.first
        else { return nil }
        // Glyph ids are only meaningful in the primary font; reject runs
        // Core Text shaped with a fallback.
        let runAttributes = CTRunGetAttributes(run) as NSDictionary
        if let runFont = runAttributes[kCTFontAttributeName as String] {
            let name = CTFontCopyPostScriptName(runFont as! CTFont)
            guard name == CTFontCopyPostScriptName(fonts[0]) else { return nil }
        }
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { return nil }
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        return zip(glyphs, positions).map {
            ShapedGlyph(glyph: $0, xOffsetPx: Float($1.x * scale))
        }
    }

    /// Atlas entry for a shaped glyph id (always the primary font).
    func entry(forPrimaryGlyph glyph: CGGlyph) -> Entry? {
        let key = Key(fontIndex: 0, glyph: glyph)
        if let cached = entries[key] { return cached }
        let entry = rasterize(fonts[0], glyph, color: false)
        entries[key] = entry
        return entry
    }

    func entry(forScalar scalar: UInt32) -> Entry? {
        // Box drawing and block elements never come from the font: glyphs
        // there don't fill the rounded-up cell (or come from a fallback with
        // foreign metrics), leaving seams. Synthesized from cell geometry.
        if BoxDrawing.covers(scalar) {
            if let cached = boxEntries[scalar] { return cached }
            let entry = rasterizeBox(scalar)
            boxEntries[scalar] = entry
            return entry
        }
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

    /// The bundled Symbols Nerd Font, appended to `fonts` on first use with
    /// its index cached here. nil when the font failed to register (e.g. a
    /// test host without the resource bundle), in which case private-use
    /// scalars fall through to the generic system fallback. Created at the
    /// primary font's point size so its icons share the run's metrics.
    private lazy var symbolsFontIndex: UInt16? = {
        let font = CTFontCreateWithName(
            BundledFonts.symbolsNerdFont as CFString, CTFontGetSize(fonts[0]), nil)
        // CTFontCreateWithName substitutes a default face for an unknown
        // name; confirm we got the bundled font before trusting it.
        guard CTFontCopyPostScriptName(font)
            == BundledFonts.symbolsNerdFont as CFString else { return nil }
        fonts.append(font)
        return UInt16(fonts.count - 1)
    }()

    /// Nerd Font / Powerline icons live in the Unicode private-use areas —
    /// the whole BMP PUA (U+E000–F8FF) and Supplementary PUA-A (U+F0000–FFFFD,
    /// where Material Design Icons sit). The primary font lacks them and
    /// macOS has no system fallback there, so they route to the symbols font.
    private static func isPrivateUse(_ scalar: UInt32) -> Bool {
        (0xE000...0xF8FF).contains(scalar) || (0xF0000...0xFFFFD).contains(scalar)
    }

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
        // Nerd Font / Powerline icons in the private-use areas: try the
        // bundled symbols font before the generic fallback below, which finds
        // nothing there (macOS ships no PUA coverage). Glyphs the symbols font
        // itself lacks (e.g. the Apple logo at U+F8FF) fall through.
        if Self.isPrivateUse(scalar), let index = symbolsFontIndex {
            glyphs = [CGGlyph](repeating: 0, count: units.count)
            if CTFontGetGlyphsForCharacters(
                fonts[Int(index)], units, &glyphs, units.count), glyphs[0] != 0 {
                return (index, glyphs[0])
            }
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

    /// Configures a bitmap context for glyph rasterisation so the rendered ink
    /// lands at exactly the continuous baseline `bearing.y` records — for every
    /// glyph, at every size and scale.
    ///
    /// By default Core Graphics grid-fits (hints) each glyph, snapping its
    /// baseline to a whole device pixel. The snap amount is the fractional part
    /// of the rasterise translate (`pad - rect.minY*scale`), which differs per
    /// glyph and per size, so grid-fitting pushes each glyph's baseline off
    /// `bearing.y` by a different sub-pixel (often ±1 px) amount — a ragged,
    /// size-dependent baseline that the #40 atlas-rounding fix could not reach
    /// because it lives in the rasteriser, not the bearing. It only bites at
    /// scale 1 (a 1×, non-Retina or scaled display); at 2× the grid is fine
    /// enough to absorb it. Turning on subpixel positioning (and off the
    /// quantiser that would re-snap it to quarter-pixels) removes the snap.
    static func configureGlyphRendering(_ context: CGContext) {
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
    }

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
            Self.configureGlyphRendering(context)
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
            // The glyph is positioned against the bitmap's bottom-left with an
            // exact integer `pad` (see the translate above), so both bearings
            // must be measured from that same anchored, un-rounded edge. The X
            // bearing is the gap from the pen to the glyph's left, anchored to
            // minX. The Y bearing is the distance from the texture's top down to
            // the baseline; the baseline sits `pad - rect.minY*scale` up from the
            // bottom, so from the top that is `height - pad + rect.minY*scale`.
            // Deriving it from the rounded-up `height` (not `rect.maxY`) keeps the
            // baseline exact: computing it from maxY instead drops the fractional
            // part lost to height's `.rounded(.up)`, shifting each glyph's
            // baseline down by a per-glyph, size-dependent sub-pixel amount.
            bearing: SIMD2(
                Float(rect.minX * scale) - Float(pad),
                Float(height - pad) + Float(rect.minY * scale)),
            isColor: color,
            isEmpty: false)
    }

    /// Procedural box-drawing/block-element entry: the bitmap is exactly one
    /// cell (plus the atlas gutter) and the bearing pins the quad to the cell
    /// rect, so adjacent cells tile with no seams.
    private func rasterizeBox(_ scalar: UInt32) -> Entry {
        let pad = 1
        let width = cellWidthPx + 2 * pad
        let height = cellHeightPx + 2 * pad
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
            context.translateBy(x: CGFloat(pad), y: CGFloat(pad))
            BoxDrawing.draw(
                scalar, in: context, width: cellWidthPx, height: cellHeightPx)
        }

        guard let slot = grayPacker.allocate(width: width, height: height) else {
            return .empty
        }
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
            bearing: SIMD2(-Float(pad), ascentPx + Float(pad)),
            isColor: false,
            isEmpty: false)
    }
}
