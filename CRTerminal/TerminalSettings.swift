import AppKit
import CRTRendering

/// Everything a new surface needs to configure itself. One global set of
/// settings for the whole app — persisted as JSON in UserDefaults via
/// SettingsStore. (Not named `Settings.swift`: that file holds the view, and
/// a `Settings`/`Main`-style basename collision is best avoided.)
/// When to bring windows/tabs/splits back on relaunch (session restoration
/// R3), Ghostty-style. `system` defers to the macOS "Close windows when
/// quitting an app" preference (via `NSWindowRestoration`); `always` restores
/// regardless (our own on-disk layout backstop); `never` disables encoding
/// and deletes any stored state.
enum RestorationMode: String, Codable, CaseIterable {
    case system, always, never
}

struct TerminalSettings: Codable, Equatable {
    var fontSize: Double = 13
    var presetName: String = "Dark"
    /// nil = the user's login shell ($SHELL).
    var shellPath: String?
    /// Where new shells start; nil = the home folder. "~" is expanded.
    var workingDirectory: String?
    var scrollbackLines: Int = 10_000
    /// Shape operator runs so font ligatures (=>, ===) apply.
    var ligatures = true
    /// Whether relaunch restores the previous windows/sessions.
    var restoration: RestorationMode = .system

    /// The typeface is fixed: everyone gets bundled Geist Mono. Only the
    /// size is configurable; system monospaced is a fallback for when
    /// registration failed (or a test host without the bundle).
    ///
    /// `name` is the PostScript face — a preset's `fontName`, or the
    /// bundled Geist Mono default. `scale` multiplies the configured size
    /// for presets that ask for it (a preset's `fontSizeScale` — the
    /// Commodore 1702 renders 25% larger in the bundled C64 face). The
    /// clamp applies after scaling; an unresolvable name falls back to the
    /// system monospaced font.
    func font(name: String = BundledFonts.geistMono, scale: Double = 1) -> NSFont {
        let size = CGFloat(max(6, min(fontSize * scale, 72)))
        if let resolved = NSFont(name: name, size: size) {
            return resolved
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The default font (Geist Mono, scale 1): the baseline the settings
    /// comparison and new, untouched presets use.
    var font: NSFont { font() }

    func preset(in presets: [CRTPreset]) -> CRTPreset {
        presets.first { $0.name == presetName } ?? .darkStandard
    }

    /// The startup directory for new shells: the preference with "~"
    /// expanded, falling back to home when unset or no longer a directory
    /// (a vanished path must not stop shells from spawning).
    var resolvedWorkingDirectory: String {
        guard let workingDirectory, !workingDirectory.isEmpty else {
            return NSHomeDirectory()
        }
        let expanded = (workingDirectory as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return NSHomeDirectory()
        }
        return expanded
    }
}

extension TerminalSettings {
    private enum CodingKeys: String, CodingKey {
        case fontSize, presetName, shellPath,
             workingDirectory, scrollbackLines, ligatures, restoration
    }

    /// Tolerant decoding, in an extension so the memberwise init survives:
    /// settings persist as JSON in UserDefaults and a failed decode silently
    /// resets to defaults — adding a field must never invalidate saved
    /// settings. (An old blob's `fontName` is simply ignored.)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        presetName = try container.decodeIfPresent(String.self, forKey: .presetName)
            ?? "Dark"
        shellPath = try container.decodeIfPresent(String.self, forKey: .shellPath)
        workingDirectory = try container.decodeIfPresent(
            String.self, forKey: .workingDirectory)
        scrollbackLines = try container.decodeIfPresent(
            Int.self, forKey: .scrollbackLines) ?? 10_000
        ligatures = try container.decodeIfPresent(Bool.self, forKey: .ligatures) ?? true
        restoration = try container.decodeIfPresent(
            RestorationMode.self, forKey: .restoration) ?? .system
    }
}

/// UserDefaults-backed global terminal settings. New windows take a snapshot;
/// edits broadcast so open windows re-apply live.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private static let settingsKey = "TerminalSettings"
    private static let legacyProfilesKey = "Profiles"     // pre-consolidation
    private static let legacyDefaultIDKey = "DefaultProfileID"
    private static let legacyPresetKey = "PresetName"     // Phase 4

    private(set) var settings: TerminalSettings
    /// Called after any mutation; windows re-apply their settings.
    var onChange: (() -> Void)?

    private let defaults: UserDefaults

    /// Injectable store so tests stay out of the real domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(TerminalSettings.self, from: data) {
            settings = decoded
        } else {
            settings = Self.migratedFromLegacy(defaults)
        }
    }

    /// Carry forward the old multi-profile world: take the former default
    /// profile's fields, else the first profile, else the Phase 4 preset.
    private static func migratedFromLegacy(_ defaults: UserDefaults) -> TerminalSettings {
        var result = TerminalSettings()
        if let data = defaults.data(forKey: legacyProfilesKey),
           let profiles = try? JSONDecoder().decode([LegacyProfile].self, from: data),
           !profiles.isEmpty {
            let chosen: LegacyProfile
            if let raw = defaults.string(forKey: legacyDefaultIDKey),
               let match = profiles.first(where: { $0.id?.uuidString == raw }) {
                chosen = match
            } else {
                chosen = profiles[0]
            }
            result.fontSize = chosen.fontSize ?? result.fontSize
            result.presetName = chosen.presetName ?? result.presetName
            result.shellPath = chosen.shellPath
            result.workingDirectory = chosen.workingDirectory
            result.scrollbackLines = chosen.scrollbackLines ?? result.scrollbackLines
            result.ligatures = chosen.ligatures ?? result.ligatures
        } else if let legacy = defaults.string(forKey: legacyPresetKey) {
            result.presetName = legacy
        }
        return result
    }

    func update(_ settings: TerminalSettings) {
        guard self.settings != settings else { return }
        self.settings = settings
        persist()
        onChange?()
    }

    /// Change just the restoration mode (used by the Settings picker and the
    /// lifecycle probes).
    func setRestoration(_ mode: RestorationMode) {
        var next = settings
        next.restoration = mode
        update(next)
    }

    /// Whether relaunch state should be encoded/kept at all.
    var restorationEnabled: Bool { settings.restoration != .never }

    /// Set the restoration mode for this launch only, without persisting —
    /// used by the lifecycle probe so its env override doesn't rewrite the
    /// user's saved settings.
    func overrideRestoration(_ mode: RestorationMode) {
        settings.restoration = mode
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }
}

/// Just enough of the retired `Profile` shape to migrate saved JSON. All
/// fields optional so a partial/old blob still decodes.
private struct LegacyProfile: Decodable {
    var id: UUID?
    var fontSize: Double?
    var presetName: String?
    var shellPath: String?
    var workingDirectory: String?
    var scrollbackLines: Int?
    var ligatures: Bool?
}
