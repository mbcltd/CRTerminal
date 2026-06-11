import Foundation

/// Loads CRT presets: the launch set bundled with this package, plus any
/// user presets dropped into Application Support as JSON documents.
public enum CRTPresetLibrary {
    /// The launch presets, in gallery order (filenames carry a numeric
    /// prefix). Decoding failures here are programmer error and trap in
    /// debug; a malformed bundled preset is skipped in release.
    public static let builtIn: [CRTPreset] = {
        guard let urls = Bundle.module.urls(
            forResourcesWithExtension: "json", subdirectory: "Presets") else {
            assertionFailure("bundled preset directory missing")
            return [.museumOff]
        }
        let presets = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> CRTPreset? in
                do {
                    return try load(from: url)
                } catch {
                    assertionFailure("bundled preset \(url.lastPathComponent): \(error)")
                    return nil
                }
            }
        return presets.isEmpty ? [.museumOff] : presets
    }()

    public static func load(from url: URL) throws -> CRTPreset {
        try JSONDecoder().decode(CRTPreset.self, from: Data(contentsOf: url))
    }

    /// User presets from a directory (the app passes its Application
    /// Support "Presets" folder). Unreadable files are skipped.
    public static func userPresets(in directory: URL) -> [CRTPreset] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? load(from: $0) }
    }

    public static func preset(named name: String, including user: [CRTPreset] = []) -> CRTPreset? {
        (builtIn + user).first { $0.name == name }
    }
}
