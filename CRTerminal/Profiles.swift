import AppKit
import CRTRendering

/// A terminal profile: everything a new surface needs to configure itself.
/// Persisted as JSON in UserDefaults via ProfileStore.
struct Profile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Default"
    /// PostScript name; nil = the app default (bundled Geist Mono).
    var fontName: String?
    var fontSize: Double = 13
    var presetName: String = "Museum off"
    /// nil = the user's login shell ($SHELL).
    var shellPath: String?
    /// Where new shells start; nil = the home folder. "~" is expanded.
    var workingDirectory: String?
    var scrollbackLines: Int = 10_000
    /// Shape operator runs so font ligatures (=>, ===) apply.
    var ligatures = true

    var font: NSFont {
        let size = CGFloat(max(6, min(fontSize, 72)))
        if let fontName, let custom = NSFont(name: fontName, size: size) {
            return custom
        }
        // The app default: bundled Geist Mono; system monospaced only if
        // registration failed (or a test host without the bundle).
        if let geist = NSFont(name: BundledFonts.geistMono, size: size) {
            return geist
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func preset(in presets: [CRTPreset]) -> CRTPreset {
        presets.first { $0.name == presetName } ?? .museumOff
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

extension Profile {
    private enum CodingKeys: String, CodingKey {
        case id, name, fontName, fontSize, presetName, shellPath,
             workingDirectory, scrollbackLines, ligatures
    }

    /// Tolerant decoding, in an extension so the memberwise init
    /// survives: profiles persist as JSON in UserDefaults and a failed
    /// decode silently resets to defaults — adding a field must never
    /// invalidate saved profiles.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Default"
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        presetName = try container.decodeIfPresent(String.self, forKey: .presetName)
            ?? "Museum off"
        shellPath = try container.decodeIfPresent(String.self, forKey: .shellPath)
        workingDirectory = try container.decodeIfPresent(
            String.self, forKey: .workingDirectory)
        scrollbackLines = try container.decodeIfPresent(
            Int.self, forKey: .scrollbackLines) ?? 10_000
        ligatures = try container.decodeIfPresent(Bool.self, forKey: .ligatures) ?? true
    }
}

/// UserDefaults-backed profile list. New windows take the default profile;
/// edits broadcast so open windows can re-apply live.
@MainActor
final class ProfileStore {
    static let shared = ProfileStore()

    private static let profilesKey = "Profiles"
    private static let defaultIDKey = "DefaultProfileID"
    private static let legacyPresetKey = "PresetName" // Phase 4

    private(set) var profiles: [Profile]
    var defaultProfileID: UUID {
        didSet { persist() }
    }
    /// Called after any mutation; windows re-apply their profile.
    var onChange: (() -> Void)?

    var defaultProfile: Profile {
        profiles.first { $0.id == defaultProfileID } ?? profiles[0]
    }

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data),
           !decoded.isEmpty {
            profiles = decoded
        } else {
            var initial = Profile()
            // Migrate the Phase 4 preset choice into the default profile.
            if let legacy = defaults.string(forKey: Self.legacyPresetKey) {
                initial.presetName = legacy
            }
            profiles = [initial]
        }
        if let raw = defaults.string(forKey: Self.defaultIDKey),
           let id = UUID(uuidString: raw),
           profiles.contains(where: { $0.id == id }) {
            defaultProfileID = id
        } else {
            defaultProfileID = profiles[0].id
        }
    }

    func profile(id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    func update(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard profiles[index] != profile else { return }
        profiles[index] = profile
        persist()
        onChange?()
    }

    func add(_ profile: Profile) {
        profiles.append(profile)
        persist()
        onChange?()
    }

    func remove(id: UUID) {
        guard profiles.count > 1 else { return } // always keep one
        profiles.removeAll { $0.id == id }
        if defaultProfileID == id {
            defaultProfileID = profiles[0].id
        }
        persist()
        onChange?()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.profilesKey)
        }
        defaults.set(defaultProfileID.uuidString, forKey: Self.defaultIDKey)
    }
}
