import AppKit
import CRTRendering
import SwiftUI

/// The settings window: one global set of terminal settings, the CRT preset
/// gallery, and alerts, in a single scrolling pane. Edits write through to
/// SettingsStore / AlertSettings, which broadcast so open windows re-apply
/// live.
struct SettingsView: View {
    /// Bumped on every write so SwiftUI re-reads the pass-through binding.
    @State private var revision = 0
    let preview: PresetPreviewRenderer

    @MainActor
    init(preview: PresetPreviewRenderer) {
        self.preview = preview
    }

    private var settings: Binding<TerminalSettings> {
        Binding(
            get: { _ = revision; return SettingsStore.shared.settings },
            set: { SettingsStore.shared.update($0); revision += 1 })
    }

    /// The font picker works in family names; the default family maps back to
    /// a nil `fontName` (the bundled Geist Mono default), so the stored value
    /// stays meaningful even if Geist Mono is ever renamed or removed.
    private var fontSelection: Binding<String> {
        Binding(
            get: {
                _ = revision
                return SettingsStore.shared.settings.fontName ?? MonospacedFonts.defaultFamily
            },
            set: { newValue in
                var updated = SettingsStore.shared.settings
                updated.fontName = newValue == MonospacedFonts.defaultFamily ? nil : newValue
                SettingsStore.shared.update(updated)
                revision += 1
            })
    }

    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Font", selection: fontSelection) {
                    ForEach(MonospacedFonts.all, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Slider(value: settings.fontSize, in: 9...32, step: 1) {
                    Text("Size: \(Int(settings.wrappedValue.fontSize)) pt")
                }
                Toggle("Font ligatures (=> becomes an arrow)", isOn: settings.ligatures)
                TextField(
                    "Scrollback lines",
                    value: settings.scrollbackLines, format: .number)
                TextField(
                    "Shell", text: Binding(
                        get: { settings.wrappedValue.shellPath ?? "" },
                        set: { settings.wrappedValue.shellPath = $0.isEmpty ? nil : $0 }),
                    prompt: Text("Login shell ($SHELL)"))
                TextField(
                    "Working directory", text: Binding(
                        get: { settings.wrappedValue.workingDirectory ?? "" },
                        set: {
                            settings.wrappedValue.workingDirectory = $0.isEmpty ? nil : $0
                        }),
                    prompt: Text("Home folder (~)"))
                Text("Shell changes apply to new tabs; theme changes apply immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Default theme") {
                PresetGalleryView(
                    presets: PresetCatalog.all,
                    preview: preview,
                    selectedName: settings.wrappedValue.presetName
                ) { preset in
                    settings.wrappedValue.presetName = preset.name
                }
            }

            Section("Restore windows on relaunch") {
                Picker("When reopening crterm", selection: settings.restoration) {
                    Text("System default").tag(RestorationMode.system)
                    Text("Always").tag(RestorationMode.always)
                    Text("Never").tag(RestorationMode.never)
                }
                .pickerStyle(.segmented)
                Text(restorationBlurb(settings.wrappedValue.restoration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            alertSections
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, minHeight: 480)
    }

    /// Which surfaces a bell reaches. Toggles write straight through to
    /// AlertSettings, which broadcasts to open windows.
    private var alertSections: some View {
        Group {
            Section("Every bell") {
                Toggle("Sound", isOn: alert(\.bellSound))
                Toggle("Visual bell (flash the pane)", isOn: alert(\.visualBell))
            }
            Section("Sessions you aren't watching") {
                Toggle("Badge the sidebar row", isOn: alert(\.sidebarBadges))
                Toggle("Badge the Dock icon", isOn: alert(\.dockBadge))
            }
            Section("While crterm is in the background") {
                Toggle("Post a notification", isOn: alert(\.notifications))
                Toggle("Bounce the Dock icon", isOn: alert(\.dockBounce))
            }
        }
    }

    private func restorationBlurb(_ mode: RestorationMode) -> String {
        switch mode {
        case .system:
            return "Follow the macOS “Close windows when quitting an app” setting."
        case .always:
            return "Reopen your windows, tabs, splits and scrollback every launch."
        case .never:
            return "Always start fresh; no session state is written to disk."
        }
    }

    private func alert(
        _ keyPath: ReferenceWritableKeyPath<AlertSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { _ = revision; return AlertSettings.shared[keyPath: keyPath] },
            set: { AlertSettings.shared[keyPath: keyPath] = $0; revision += 1 })
    }
}

/// The monospaced typefaces offered in the font picker: the bundled faces
/// first (process-registered, so they don't reliably surface in
/// NSFontManager's lists), then every fixed-pitch family installed on the
/// system — which is how a user's "Fira Mono for Powerline" and friends
/// appear. Built once; the scan over installed families is not free.
@MainActor
enum MonospacedFonts {
    /// The picker's stand-in for a nil `fontName` (the bundled default).
    static let defaultFamily = "Geist Mono"

    static let all: [String] = {
        let manager = NSFontManager.shared
        let system = manager.availableFontFamilies.filter(isMonospaced)
        var seen = Set<String>()
        return (BundledFonts.families + system).filter { seen.insert($0).inserted }
    }()

    private static func isMonospaced(_ family: String) -> Bool {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        guard let font = NSFont(descriptor: descriptor, size: 12) else { return false }
        // `isFixedPitch` only reflects the author-set flag in the font's `post`
        // table, which many genuinely monospaced faces leave unset. CoreText's
        // `monoSpace` symbolic trait is derived from the actual glyph metrics,
        // so it catches those the flag misses; OR the two to cover both.
        return font.fontDescriptor.symbolicTraits.contains(.monoSpace) || font.isFixedPitch
    }
}
