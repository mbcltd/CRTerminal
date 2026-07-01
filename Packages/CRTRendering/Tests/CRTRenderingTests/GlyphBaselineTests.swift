import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import CRTRendering

/// Guards the per-glyph baseline against grid-fitting regressions (#40's
/// recurrence). A glyph's ink must land on the continuous baseline `bearing.y`
/// records; Core Graphics' default grid-fitting snaps it per glyph, giving a
/// ragged baseline that only shows at scale 1 (a 1×/non-Retina/scaled display)
/// and at some sizes (it was reported clean at 18 pt, ragged at 19 pt).
struct GlyphBaselineTests {
    /// Rasterises `char` exactly as `GlyphAtlas` does and returns how far the
    /// bottom ink row sits from the continuous baseline the atlas encodes in
    /// `bearing.y`. Glyphs with the same bounding box must return the same
    /// value; grid-fitting makes them diverge by up to a whole pixel.
    private func baselineDelta(_ char: Character, font: CTFont, scale: CGFloat) -> Double? {
        var units = Array(String(char).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) else { return nil }
        var glyph = glyphs[0]
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, &rect, 1)
        guard !rect.isEmpty else { return nil }

        let pad = 1
        let width = Int((rect.width * scale).rounded(.up)) + 2 * pad
        let height = Int((rect.height * scale).rounded(.up)) + 2 * pad
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            GlyphAtlas.configureGlyphRendering(context)
            context.translateBy(x: CGFloat(pad) - rect.minX * scale,
                                y: CGFloat(pad) - rect.minY * scale)
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(gray: 1, alpha: 1)
            var position = CGPoint.zero
            var g = glyph
            CTFontDrawGlyphs(font, &g, &position, 1, context)
        }
        var inkBottom = -1
        for row in 0..<height where (0..<width).contains(where: { pixels[row * width + $0] > 40 }) {
            inkBottom = row
        }
        guard inkBottom >= 0 else { return nil }
        let bearingY = Double(height - pad) + Double(rect.minY * scale)
        return Double(inkBottom) - bearingY
    }

    /// 'a', 'o', 'e' and 'd' share the same bounding-box bottom (a rounded
    /// overshoot), so their ink must sit at the same offset below the baseline.
    /// Before the fix, at scale 1 and 19 pt, 'd' snapped a full pixel off the
    /// others. Checks the two sizes the user contrasted (18 clean, 19 ragged).
    @Test(arguments: [18.0, 19.0])
    func roundGlyphsShareBaselineAtScale1(pointSize: Double) throws {
        RenderTestSupport.ready()
        let font = CTFontCreateWithName(BundledFonts.geistMono as CFString, CGFloat(pointSize), nil)
        let deltas = try ["a", "o", "e", "d"].map {
            try #require(baselineDelta(Character($0), font: font, scale: 1))
        }
        let spread = deltas.max()! - deltas.min()!
        #expect(spread < 0.5, "baseline spread \(spread) across round glyphs at \(pointSize)pt: \(deltas)")
    }

    /// Flat-bottom glyphs of differing heights must share one baseline too.
    @Test(arguments: [18.0, 19.0])
    func flatGlyphsShareBaselineAtScale1(pointSize: Double) throws {
        RenderTestSupport.ready()
        let font = CTFontCreateWithName(BundledFonts.geistMono as CFString, CGFloat(pointSize), nil)
        let deltas = try ["l", "n", "H", "t", "E", "L"].map {
            try #require(baselineDelta(Character($0), font: font, scale: 1))
        }
        let spread = deltas.max()! - deltas.min()!
        #expect(spread < 0.5, "baseline spread \(spread) across flat glyphs at \(pointSize)pt: \(deltas)")
    }
}
