import AppKit
import CRTRendering

/// The "Auto" theme: not a monitor of its own but a rule — wear the Light
/// standard while macOS is in light mode and the Dark standard in dark
/// mode, switching live whenever the system appearance changes (a manual
/// flip in System Settings, or the "Auto" schedule at sunset).
///
/// It lists in the preset catalog like any other theme so the gallery, the
/// titlebar switcher, the theme menu, settings and layout snapshots all
/// carry it by name. Nothing draws it directly: a session remembers Auto
/// as its *chosen* preset and wears whichever standard `resolve` picks,
/// re-resolved by the AppDelegate's appearance observer.
enum AutoTheme {
    static let name = "Auto"
    static let darkPresetName = CRTPreset.darkStandard.name
    static let lightPresetName = CRTPreset.lightStandard.name

    /// The catalog entry. Effects off (so no degauss button) and the dark
    /// scheme by default; consumers that could draw it resolve it first.
    static let catalogEntry = CRTPreset(
        name: name,
        blurb: "Follows the system appearance: Light by day, Dark at night.",
        effects: false)

    static func isAuto(_ preset: CRTPreset) -> Bool { preset.name == name }

    /// Whether macOS is currently drawing in dark mode. Reads the app's
    /// effective appearance, which tracks the system setting (crterm never
    /// pins its own).
    static var systemIsDark: Bool {
        NSApplication.shared.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The concrete preset to draw for a chosen theme: `preset` itself
    /// unless it is Auto, in which case the standard matching `darkMode`,
    /// looked up in `presets` so a user override of "Dark"/"Light" wins,
    /// falling back to the built-in standards.
    static func resolve(_ preset: CRTPreset, in presets: [CRTPreset],
                        darkMode: Bool) -> CRTPreset {
        guard isAuto(preset) else { return preset }
        let target = darkMode ? darkPresetName : lightPresetName
        return presets.first { $0.name == target }
            ?? (darkMode ? .darkStandard : .lightStandard)
    }

    /// `resolve` against the live catalog and the current system appearance.
    static func resolve(_ preset: CRTPreset) -> CRTPreset {
        resolve(preset, in: PresetCatalog.all, darkMode: systemIsDark)
    }

    /// Inserts the Auto entry into a preset list, right after the standards
    /// it switches between (after Light, else after Dark, else first).
    static func inserting(into presets: [CRTPreset]) -> [CRTPreset] {
        var result = presets.filter { !isAuto($0) }
        let anchor = result.firstIndex { $0.name == lightPresetName }
            ?? result.firstIndex { $0.name == darkPresetName }
        result.insert(catalogEntry, at: anchor.map { $0 + 1 } ?? 0)
        return result
    }

    /// A gallery/menu thumbnail for Auto: the light rendering in the top-
    /// left triangle and the dark one in the bottom-right, split on the
    /// diagonal so the card reads as "both, depending". Both inputs come
    /// from the same preview renderer, so they share a size.
    static func compositeThumbnail(light: CGImage, dark: CGImage) -> CGImage? {
        let width = light.width, height = light.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(dark, in: frame)
        // CoreGraphics origin is bottom-left: the light triangle spans the
        // top-left corner, bounded by the bottom-left → top-right diagonal.
        context.saveGState()
        context.beginPath()
        context.move(to: CGPoint(x: 0, y: 0))
        context.addLine(to: CGPoint(x: 0, y: height))
        context.addLine(to: CGPoint(x: width, y: height))
        context.closePath()
        context.clip()
        context.draw(light, in: frame)
        context.restoreGState()
        return context.makeImage()
    }
}
