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

    var body: some View {
        Form {
            Section("Terminal") {
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
