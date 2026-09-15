import AppKit
import CRTRendering
import Testing
@testable import CRTerminal

struct AutoThemeTests {
    private let tube = CRTPreset(name: "Tube", effects: true)

    @Test func autoResolvesToTheStandardMatchingTheSystemMode() {
        let catalog = [CRTPreset.darkStandard, .lightStandard, AutoTheme.catalogEntry, tube]
        #expect(AutoTheme.resolve(AutoTheme.catalogEntry, in: catalog, darkMode: true)
            == .darkStandard)
        #expect(AutoTheme.resolve(AutoTheme.catalogEntry, in: catalog, darkMode: false)
            == .lightStandard)
    }

    @Test func explicitThemesPassThroughUntouched() {
        let catalog = [CRTPreset.darkStandard, .lightStandard, AutoTheme.catalogEntry, tube]
        #expect(AutoTheme.resolve(tube, in: catalog, darkMode: true) == tube)
        #expect(AutoTheme.resolve(tube, in: catalog, darkMode: false) == tube)
        #expect(AutoTheme.resolve(.lightStandard, in: catalog, darkMode: true) == .lightStandard)
    }

    @Test func autoPrefersTheCatalogsOwnStandards() {
        // A user preset file may override "Dark" (the catalog keeps the
        // bundled one, but the lookup must still go by name, not identity).
        var customDark = CRTPreset.darkStandard
        customDark.blurb = "user override"
        let catalog = [customDark, CRTPreset.lightStandard, AutoTheme.catalogEntry]
        #expect(AutoTheme.resolve(AutoTheme.catalogEntry, in: catalog, darkMode: true)
            == customDark)
    }

    @Test func autoFallsBackToBuiltInStandardsWhenTheCatalogLacksThem() {
        #expect(AutoTheme.resolve(AutoTheme.catalogEntry, in: [tube], darkMode: true)
            == .darkStandard)
        #expect(AutoTheme.resolve(AutoTheme.catalogEntry, in: [tube], darkMode: false)
            == .lightStandard)
    }

    @Test func autoSlotsInAfterTheStandardsItFollows() {
        let names = AutoTheme.inserting(into: [.darkStandard, .lightStandard, tube]).map(\.name)
        #expect(names == ["Dark", "Light", "Auto", "Tube"])
        // Without a Light entry it follows Dark; without either it leads.
        #expect(AutoTheme.inserting(into: [tube, .darkStandard]).map(\.name)
            == ["Tube", "Dark", "Auto"])
        #expect(AutoTheme.inserting(into: [tube]).map(\.name) == ["Auto", "Tube"])
        // Idempotent: re-inserting doesn't duplicate.
        let twice = AutoTheme.inserting(into: AutoTheme.inserting(into: [.darkStandard]))
        #expect(twice.filter(AutoTheme.isAuto).count == 1)
    }

    @Test @MainActor func theCatalogListsAutoOnce() {
        #expect(PresetCatalog.all.filter(AutoTheme.isAuto).count == 1)
        // Auto is never a CRT, so it can't sprout a degauss button.
        #expect(AutoTheme.catalogEntry.effects == false)
    }

    @Test func thumbnailShowsLightTopLeftAndDarkBottomRight() throws {
        let light = try #require(solidImage(red: 240, green: 240, blue: 240))
        let dark = try #require(solidImage(red: 10, green: 10, blue: 10))
        let composite = try #require(AutoTheme.compositeThumbnail(light: light, dark: dark))
        #expect(composite.width == 40 && composite.height == 20)
        // Rows are top-down in the bitmap; the diagonal runs bottom-left to
        // top-right, so (x: 2, y: 2) sits in the light triangle and the
        // far bottom-right corner in the dark one.
        #expect(pixel(of: composite, x: 2, y: 2).red > 200)
        #expect(pixel(of: composite, x: 37, y: 17).red < 50)
    }

    private func solidImage(red: UInt8, green: UInt8, blue: UInt8) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(
            red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255,
            alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        return context.makeImage()
    }

    private func pixel(of image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw the image offset so the wanted pixel lands at the 1×1 origin
        // (CoreGraphics y is bottom-up).
        context.draw(image, in: CGRect(
            x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (rgba[0], rgba[1], rgba[2])
    }
}
