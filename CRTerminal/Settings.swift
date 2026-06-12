import AppKit
import CRTRendering
import SwiftUI

/// The settings window: profile editing plus the CRT preset gallery.
/// Edits write through to ProfileStore, which broadcasts so open windows
/// re-apply live.
struct SettingsView: View {
    @State private var profiles: [Profile]
    @State private var selectedID: UUID
    @State private var defaultID: UUID
    let preview: PresetPreviewRenderer

    @MainActor
    init(preview: PresetPreviewRenderer) {
        let store = ProfileStore.shared
        _profiles = State(initialValue: store.profiles)
        _selectedID = State(initialValue: store.defaultProfileID)
        _defaultID = State(initialValue: store.defaultProfileID)
        self.preview = preview
    }

    private var selected: Binding<Profile> {
        Binding(
            get: { profiles.first { $0.id == selectedID } ?? profiles[0] },
            set: { profile in
                guard let index = profiles.firstIndex(where: { $0.id == profile.id })
                else { return }
                profiles[index] = profile
                ProfileStore.shared.update(profile)
            })
    }

    var body: some View {
        TabView {
            profileTab
                .tabItem { Label("Profile", systemImage: "person.crop.square") }
            PresetGalleryView(
                presets: PresetCatalog.all,
                preview: preview,
                selectedName: selected.wrappedValue.presetName
            ) { preset in
                selected.wrappedValue.presetName = preset.name
            }
            .tabItem { Label("Presets", systemImage: "tv") }
            AlertsSettingsView()
                .tabItem { Label("Alerts", systemImage: "bell") }
        }
        .frame(minWidth: 620, minHeight: 480)
    }

    private var profileTab: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(profiles) { profile in
                        HStack {
                            Text(profile.name)
                            if profile.id == defaultID {
                                Spacer()
                                Text("default")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(profile.id)
                    }
                }
                HStack(spacing: 4) {
                    Button {
                        var copy = selected.wrappedValue
                        copy.id = UUID()
                        copy.name += " copy"
                        profiles.append(copy)
                        ProfileStore.shared.add(copy)
                        selectedID = copy.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        let id = selectedID
                        guard profiles.count > 1 else { return }
                        profiles.removeAll { $0.id == id }
                        ProfileStore.shared.remove(id: id)
                        selectedID = profiles[0].id
                        defaultID = ProfileStore.shared.defaultProfileID
                    } label: { Image(systemName: "minus") }
                    .disabled(profiles.count <= 1)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 150, maxWidth: 220)

            Form {
                TextField("Name", text: selected.name)
                Picker("Font", selection: selected.fontName) {
                    Text("System monospaced").tag(String?.none)
                    ForEach(Self.monospacedFonts, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                Slider(value: selected.fontSize, in: 9...32, step: 1) {
                    Text("Size: \(Int(selected.wrappedValue.fontSize)) pt")
                }
                Picker("CRT preset", selection: selected.presetName) {
                    ForEach(PresetCatalog.all, id: \.name) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                TextField(
                    "Shell", text: Binding(
                        get: { selected.wrappedValue.shellPath ?? "" },
                        set: { selected.wrappedValue.shellPath = $0.isEmpty ? nil : $0 }),
                    prompt: Text("Login shell ($SHELL)"))
                TextField(
                    "Working directory", text: Binding(
                        get: { selected.wrappedValue.workingDirectory ?? "" },
                        set: { selected.wrappedValue.workingDirectory = $0.isEmpty ? nil : $0 }),
                    prompt: Text("Home folder (~)"))
                TextField(
                    "Scrollback lines",
                    value: selected.scrollbackLines, format: .number)
                Toggle("Default profile for new windows", isOn: Binding(
                    get: { defaultID == selectedID },
                    set: { on in
                        guard on else { return }
                        defaultID = selectedID
                        ProfileStore.shared.defaultProfileID = selectedID
                    }))
                Text("Font and shell changes apply to new tabs; preset changes apply immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(minWidth: 360, maxWidth: .infinity)
        }
        .padding(.top, 1)
    }

    @MainActor
    private static let monospacedFonts: [String] = {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        // Family representatives only, to keep the list scannable.
        return Array(Set(names.compactMap { name -> String? in
            guard let font = NSFont(name: name, size: 12) else { return nil }
            return font.familyName
        })).sorted()
    }()
}

/// The Alerts tab: which surfaces a bell reaches. Toggles write straight
/// through to AlertSettings, which broadcasts to open windows.
struct AlertsSettingsView: View {
    /// Bumped on every write so SwiftUI re-reads the pass-through bindings.
    @State private var revision = 0

    private func setting(
        _ keyPath: ReferenceWritableKeyPath<AlertSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { _ = revision; return AlertSettings.shared[keyPath: keyPath] },
            set: { AlertSettings.shared[keyPath: keyPath] = $0; revision += 1 })
    }

    var body: some View {
        Form {
            Section("Every bell") {
                Toggle("Sound", isOn: setting(\.bellSound))
                Toggle("Visual bell (flash the pane)", isOn: setting(\.visualBell))
            }
            Section("Sessions you aren't watching") {
                Toggle("Badge the sidebar row", isOn: setting(\.sidebarBadges))
                Toggle("Badge the Dock icon", isOn: setting(\.dockBadge))
            }
            Section("While CRTerminal is in the background") {
                Toggle("Post a notification", isOn: setting(\.notifications))
                Toggle("Bounce the Dock icon", isOn: setting(\.dockBounce))
            }
        }
        .formStyle(.grouped)
    }
}
