import CoreText
import Metal
import Testing
import TerminalCore
@testable import CRTRendering

struct BundledFontTests {
    @Test func bundledFontsRegisterAndResolve() {
        BundledFonts.register()
        for name in [BundledFonts.geistMono, BundledFonts.departureMono, BundledFonts.c64] {
            // CTFontCreateWithName falls back silently; the PostScript
            // name only matches when registration actually worked.
            let font = CTFontCreateWithName(name as CFString, 13, nil)
            #expect(CTFontCopyPostScriptName(font) as String == name)
        }
    }
}

struct LigatureTests {
    private func makeAtlas() -> GlyphAtlas? {
        BundledFonts.register()
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let font = CTFontCreateWithName(BundledFonts.geistMono as CFString, 12, nil)
        return GlyphAtlas(
            device: device, font: font, scale: 1,
            cellSize: CGSize(width: 8, height: 15), ascent: 11)
    }

    private func makeRenderer() -> TerminalRenderer? {
        BundledFonts.register()
        return TerminalRenderer(
            font: CTFontCreateWithName(BundledFonts.geistMono as CFString, 12, nil),
            scale: 1)
    }

    @Test func shapingSubstitutesArrowGlyphs() throws {
        guard let atlas = makeAtlas() else { return }
        let arrow = try #require(atlas.shape("=>"))
        let equals = try #require(atlas.shape("="))
        let greater = try #require(atlas.shape(">"))
        // Geist Mono's calt rewrites the pair; char-by-char ids must not
        // survive shaping.
        #expect(arrow.map(\.glyph) != equals.map(\.glyph) + greater.map(\.glyph))
        // Cached result is stable.
        #expect(atlas.shape("=>") == arrow)
    }

    @Test func shapedOffsetsStayOnTheGrid() throws {
        guard let atlas = makeAtlas() else { return }
        // Whatever the substitution, the run is two cells wide: every
        // shaped glyph must start inside it (offsets are pre-scale points
        // times scale 1, one Geist Mono cell ≈ 7.2 pt at 12 pt).
        let shaped = try #require(atlas.shape("=>"))
        #expect(!shaped.isEmpty)
        #expect(shaped.allSatisfy { $0.xOffsetPx >= 0 && $0.xOffsetPx < 2 * 8 })
    }

    @Test func ligaturesChangeTheRenderedImage() throws {
        guard let renderer = makeRenderer() else { return }
        var terminal = Terminal(columns: 10, rows: 2)
        terminal.feed(Array("a => b".utf8))

        renderer.setLigatures(true)
        let ligated = try #require(renderer.renderImage(terminal.state))
        renderer.setLigatures(false)
        let plain = try #require(renderer.renderImage(terminal.state))
        #expect(
            (ligated.dataProvider!.data! as Data) != (plain.dataProvider!.data! as Data))
    }

    @Test func ligaturesLeaveProseUntouched() throws {
        guard let renderer = makeRenderer() else { return }
        var terminal = Terminal(columns: 10, rows: 2)
        terminal.feed(Array("hello 123".utf8))

        renderer.setLigatures(true)
        let on = try #require(renderer.renderImage(terminal.state))
        renderer.setLigatures(false)
        let off = try #require(renderer.renderImage(terminal.state))
        #expect((on.dataProvider!.data! as Data) == (off.dataProvider!.data! as Data))
    }

    @Test func styleChangeBreaksTheRun() throws {
        guard let renderer = makeRenderer() else { return }
        // "=" red, ">" default: must not ligate across the color change.
        var split = Terminal(columns: 10, rows: 2)
        split.feed(Array("\u{1B}[31m=\u{1B}[0m>".utf8))
        var plain = Terminal(columns: 10, rows: 2)
        plain.feed(Array("=>".utf8))

        renderer.setLigatures(true)
        let splitImage = try #require(renderer.renderImage(split.state))
        let arrowImage = try #require(renderer.renderImage(plain.state))
        #expect(
            (splitImage.dataProvider!.data! as Data)
                != (arrowImage.dataProvider!.data! as Data))
    }
}
