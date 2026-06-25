import CoreText
import Foundation
import Testing
@testable import CRTRendering

struct CRTPresetTests {
    @Test func launchSetLoadsInGalleryOrder() {
        let names = CRTPresetLibrary.builtIn.map(\.name)
        #expect(names == [
            "Dark", "Light", "Danger",
            "IBM 5151", "DEC VT220", "Amdek 310A", "Commodore 1702",
            "RPG",
        ])
    }

    @Test func standardPresetsDisableEffects() throws {
        let dark = try #require(CRTPresetLibrary.preset(named: "Dark"))
        #expect(!dark.effects)
        #expect(dark.appearance == .dark)
        let light = try #require(CRTPresetLibrary.preset(named: "Light"))
        #expect(!light.effects)
        #expect(light.appearance == .light)
    }

    @Test func bundledPresetsAreSane() {
        for preset in CRTPresetLibrary.builtIn where preset.effects {
            #expect(preset.phosphor.decayMs >= 0, "\(preset.name)")
            #expect((0...1).contains(preset.mask.strength), "\(preset.name)")
            #expect((0...1).contains(preset.scanlines.strength), "\(preset.name)")
            #expect(preset.scanlines.lines > 0 || preset.scanlines.strength == 0,
                    "\(preset.name): scan lines need a line count")
            #expect(preset.mask.type == .none || preset.mask.pitchMM > 0, "\(preset.name)")
        }
    }

    @Test func dangerCarriesACrimsonPalette() throws {
        let danger = try #require(CRTPresetLibrary.preset(named: "Danger"))
        #expect(!danger.effects)
        #expect(danger.appearance == .dark)
        let bar = try #require(danger.bottomBar)              // the warning stripe
        #expect(bar.thicknessPt == 12)
        #expect(bar.color == HexColor(0x6E, 0x14, 0x23))     // darker burgundy
        let colors = try #require(danger.colors)
        #expect(colors.red == HexColor(0xFF, 0x5D, 0x62))     // the red prompt
        #expect(colors.background == HexColor(0x2A, 0x0A, 0x0F))

        // The explicit palette becomes the scheme: foreground/background and
        // the overridden ANSI red flow through, untouched slots keep xterm.
        let scheme = ColorScheme(palette: colors)
        #expect(scheme.foreground == ColorScheme.pack(0xFF, 0xE6, 0xE3))
        #expect(scheme.background == ColorScheme.pack(0x2A, 0x0A, 0x0F))
        #expect(scheme.palette[1] == ColorScheme.pack(0xFF, 0x5D, 0x62)) // ANSI red
        // 256-cube entry the palette never touches stays the xterm default.
        #expect(scheme.palette[196] == ColorScheme.pack(0xFF, 0x00, 0x00))
    }

    @Test func resolveSchemePicksLightDarkOrPalette() throws {
        // Appearance drives the built-in scheme; an explicit palette overrides
        // it. Shared by the renderer and the OSC 10/11 color reporting.
        #expect(ColorScheme.resolve(for: .darkStandard).background
            == ColorScheme.default.background)
        #expect(ColorScheme.resolve(for: .lightStandard).background
            == ColorScheme.light.background)
        let danger = try #require(CRTPresetLibrary.preset(named: "Danger"))
        #expect(ColorScheme.resolve(for: danger).background
            == ColorScheme.pack(0x2A, 0x0A, 0x0F))
    }

    @Test func isLightBackgroundReflectsLuminance() throws {
        // The COLORFGBG hint follows the resolved background's luminance, not
        // the appearance flag, so custom palettes classify correctly too.
        #expect(!ColorScheme.resolve(for: .darkStandard).isLightBackground)
        #expect(ColorScheme.resolve(for: .lightStandard).isLightBackground)
        let danger = try #require(CRTPresetLibrary.preset(named: "Danger"))
        #expect(!ColorScheme.resolve(for: danger).isLightBackground) // dark crimson
    }

    @Test func rgbAccessorsDropAlpha() {
        let scheme = ColorScheme.light
        #expect(scheme.foregroundRGB == (0x1C, 0x1C, 0x1C))
        #expect(scheme.backgroundRGB == (0xF7, 0xF6, 0xF2))
    }

    @Test func paletteOmissionsFallBackToXterm() {
        // Only background/foreground specified: every ANSI slot stays xterm.
        let bare = CRTPreset.Palette(
            background: HexColor(0x10, 0x10, 0x10), foreground: HexColor(0xEE, 0xEE, 0xEE))
        let scheme = ColorScheme(palette: bare)
        #expect(scheme.palette == ColorScheme.default.palette)
        #expect(scheme.foreground == ColorScheme.pack(0xEE, 0xEE, 0xEE))
    }

    @Test func minimalJSONGetsDefaults() throws {
        let json = #"{ "name": "Bare" }"#
        let preset = try JSONDecoder().decode(CRTPreset.self, from: Data(json.utf8))
        #expect(preset.name == "Bare")
        #expect(preset.effects)
        #expect(preset.phosphor.decayMs == 0)
        #expect(preset.mask.type == .none)
        #expect(preset.bezel.widthPt == 0)
        #expect(!preset.artifacts.isAnimated)
        #expect(preset.colors == nil)
        #expect(preset.bottomBar == nil)
        #expect(preset.degaussButton)
        #expect(preset.text.isEmpty) // no stylised text by default
        #expect(!preset.text.shakes)
    }

    @Test func rpgCarriesItsTextStyle() throws {
        let rpg = try #require(CRTPresetLibrary.preset(named: "RPG"))
        #expect(!rpg.effects)                                 // a flat theme, no tube
        #expect(rpg.fontName == BundledFonts.pressStart2P)    // the 8-bit face
        #expect(!rpg.text.isEmpty)
        #expect(rpg.text.shakes)                              // bold wobbles
        #expect(rpg.text.shadowColor == HexColor(0x00, 0x00, 0x00))
        #expect(rpg.text.shadowOffsetPt == 4)
        #expect(rpg.text.boldColor == HexColor(0xFF, 0xD2, 0x3F)) // gold emphasis
        #expect(rpg.text.replaceEmoji)
        #expect(rpg.accentColor == HexColor(0x3A, 0x56, 0xB8)) // dark-blue sidebar hue
        // A mid-blue dungeon background.
        let scheme = ColorScheme.resolve(for: rpg)
        #expect(scheme.background == ColorScheme.pack(0x16, 0x27, 0x6B))
        #expect(!scheme.isLightBackground)
    }

    @Test func glyphSubstitutionsFoldOntoFontNativeGlyphs() {
        // The curated lo-fi swaps the RPG theme applies. Each target is a glyph
        // PressStart2P actually ships (see the invariant test below).
        let sub = TerminalRenderer.glyphSubstitutions
        #expect(sub[0x25CB] == 0x2022)  // ○ → •  (the bug that started this)
        #expect(sub[0x25CF] == 0x2022)  // ● → •
        #expect(sub[0x23FA] == 0x2022)  // ⏺ → •  (Claude Code's TUI bullet)
        #expect(sub[0x23F5] == 0x25B6)  // ⏵ → ▶  ("accept edits" indicator)
        #expect(sub[0x23F4] == 0x25C0)  // ⏴ → ◀
        #expect(sub[0x23BF] == 0x2514)  // ⎿ → └  (result-branch connector)
        #expect(sub[0x21D2] == 0x2192)  // ⇒ → →
        #expect(sub[0x21D0] == 0x2190)  // ⇐ → ←
        #expect(sub[0x2B50] == 0x2605)  // ⭐ → ★
        #expect(sub[0x2764] == 0x2665)  // ❤ → ♥
        #expect(sub[0x1F48E] == 0x2666) // 💎 → ♦
        #expect(sub[0x2705] == 0x221A)  // ✅ → √
        #expect(sub[0x274C] == 0x00D7)  // ❌ → ×
        #expect(sub[0x1F7E5] == 0x2588) // 🟥 → █
        // Glyphs the face already has are left alone.
        #expect(sub[0x2192] == nil)     // → stays →
        #expect(sub[Character("a").unicodeScalars.first!.value] == nil)
    }

    /// Every substitution *target* must be a glyph PressStart2P actually has
    /// (or one BoxDrawing synthesizes from cell geometry, like █) — otherwise
    /// the swap just trades one missing glyph for another that falls back to a
    /// metrics-foreign system face, the very thing the map exists to avoid.
    @Test func everyGlyphSubstitutionTargetExistsInPressStart2P() {
        RenderTestSupport.ready()
        let font = CTFontCreateWithName(BundledFonts.pressStart2P as CFString, 12, nil)
        for target in Set(TerminalRenderer.glyphSubstitutions.values) {
            if BoxDrawing.covers(target) { continue }
            let scalar = Unicode.Scalar(target)!
            var units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            let ok = CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
            #expect(ok && glyphs[0] != 0,
                    "U+\(String(target, radix: 16, uppercase: true)) missing in PressStart2P")
        }
    }

    @Test func commodore1702HasNoDegaussButton() throws {
        // The 1702 degaussed itself at power-on; no front-panel button.
        let preset = try #require(CRTPresetLibrary.preset(named: "Commodore 1702"))
        #expect(!preset.degaussButton)
    }

    @Test func presetRoundTripsThroughJSON() throws {
        let original = try #require(CRTPresetLibrary.preset(named: "Commodore 1702"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CRTPreset.self, from: data)
        #expect(decoded == original)
    }

    @Test func hexColorParses() {
        #expect(HexColor(string: "#FFB000") == HexColor(0xFF, 0xB0, 0x00))
        #expect(HexColor(string: "2EFF66") == HexColor(0x2E, 0xFF, 0x66))
        #expect(HexColor(string: "#XYZ") == nil)
        #expect(HexColor(string: "#FFFF") == nil)
        #expect(HexColor(0x12, 0x34, 0x56).string == "#123456")
    }

    @Test func userPresetsLoadFromDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crt-preset-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try #"{ "name": "My Tube", "geometry": { "curvature": 0.2 } }"#
            .write(to: dir.appendingPathComponent("mine.json"), atomically: true, encoding: .utf8)
        try "not json".write(
            to: dir.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

        let user = CRTPresetLibrary.userPresets(in: dir)
        #expect(user.map(\.name) == ["My Tube"])
        #expect(user.first?.geometry.curvature == 0.2)
        #expect(CRTPresetLibrary.preset(named: "My Tube", including: user) != nil)
    }
}
