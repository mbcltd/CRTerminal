import Foundation
import Testing
@testable import CRTRendering

struct CRTPresetTests {
    @Test func launchSetLoadsInGalleryOrder() {
        let names = CRTPresetLibrary.builtIn.map(\.name)
        #expect(names == [
            "Dark Standard", "Light Standard",
            "IBM 5151", "DEC VT220", "Amdek 310A", "Commodore 1702",
        ])
    }

    @Test func standardPresetsDisableEffects() throws {
        let dark = try #require(CRTPresetLibrary.preset(named: "Dark Standard"))
        #expect(!dark.effects)
        #expect(dark.appearance == .dark)
        let light = try #require(CRTPresetLibrary.preset(named: "Light Standard"))
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

    @Test func minimalJSONGetsDefaults() throws {
        let json = #"{ "name": "Bare" }"#
        let preset = try JSONDecoder().decode(CRTPreset.self, from: Data(json.utf8))
        #expect(preset.name == "Bare")
        #expect(preset.effects)
        #expect(preset.phosphor.decayMs == 0)
        #expect(preset.mask.type == .none)
        #expect(preset.bezel.widthPt == 0)
        #expect(!preset.artifacts.isAnimated)
        #expect(preset.degaussButton)
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
