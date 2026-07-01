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

            KeybindingsEditor(settings: settings)

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

/// The "Keyboard shortcuts" section: one recorder row per editable `AppCommand`,
/// grouped by the menu it lives under. Writes overrides through the passed-in
/// settings binding, so a rebind persists and rebuilds the menu live (via
/// SettingsStore's broadcast). Only shortcuts that differ from the factory
/// default are stored.
struct KeybindingsEditor: View {
    @Binding var settings: TerminalSettings
    /// Transient validation feedback (conflict / missing ⌘), cleared on success.
    @State private var message: String?

    var body: some View {
        ForEach(AppCommand.Section.allCases, id: \.self) { section in
            Section(sectionHeader(section)) {
                ForEach(AppCommand.allCases.filter { $0.section == section }, id: \.self) {
                    row(for: $0)
                }
            }
        }
        Section {
            HStack {
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Reset all to defaults") {
                    settings.keyBindings = [:]
                    message = nil
                }
                .disabled(settings.keyBindings.isEmpty)
            }
        } footer: {
            Text("Click a shortcut, then press the new combination — every "
                + "shortcut must include ⌘. Press ⎋ to cancel or ⌫ to restore "
                + "the default. Changed shortcuts sit on a paper background. Two "
                + "commands may share a shortcut (handy for swapping): they're "
                + "outlined in red, and only the first keeps it in the menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Commands whose effective binding collides with another command's — both
    /// sides of every clash. Marked with a red border in the editor.
    private var duplicated: Set<AppCommand> {
        var result: Set<AppCommand> = []
        let all = AppCommand.allCases
        for i in all.indices {
            for j in all.indices where j > i {
                if settings.binding(for: all[i]).conflicts(with: settings.binding(for: all[j])) {
                    result.insert(all[i])
                    result.insert(all[j])
                }
            }
        }
        return result
    }

    private func sectionHeader(_ section: AppCommand.Section) -> String {
        section == AppCommand.Section.allCases.first
            ? "Keyboard shortcuts — \(section.title) menu"
            : "\(section.title) menu"
    }

    private func row(for command: AppCommand) -> some View {
        let binding = settings.binding(for: command)
        let customised = settings.keyBindings[command.rawValue] != nil
        let isDuplicated = duplicated.contains(command)
        return HStack {
            Text(command.title)
            Spacer()
            ShortcutRecorderField(
                binding: binding,
                isCustomised: customised,
                isDuplicated: isDuplicated,
                onCapture: { apply($0, to: command) },
                onClear: { clear(command) })
                .frame(width: 130, height: 22)
        }
    }

    /// Stores a freshly recorded combo as an override (or drops the override when
    /// it equals the default). Combos without ⌘ are refused; duplicates across
    /// commands are allowed and flagged in the UI rather than blocked.
    private func apply(_ captured: KeyBinding, to command: AppCommand) {
        guard captured.includesCommand else {
            message = "Shortcuts must include ⌘."
            return
        }
        if captured == command.defaultBinding {
            settings.keyBindings[command.rawValue] = nil
        } else {
            settings.keyBindings[command.rawValue] = captured
        }
        message = nil
    }

    private func clear(_ command: AppCommand) {
        settings.keyBindings[command.rawValue] = nil
        message = nil
    }
}

/// A click-to-record shortcut field. Idle it shows the current combo; clicked it
/// captures the next keystroke as a `KeyBinding` and hands it to `onCapture`
/// (the parent validates). ⎋ cancels; ⌫ clears via `onClear`.
struct ShortcutRecorderField: NSViewRepresentable {
    let binding: KeyBinding
    let isCustomised: Bool
    let isDuplicated: Bool
    let onCapture: (KeyBinding) -> Void
    let onClear: () -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        view.onCapture = onCapture
        view.onClear = onClear
        view.display(binding: binding, customised: isCustomised, duplicated: isDuplicated)
        return view
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.onCapture = onCapture
        nsView.onClear = onClear
        nsView.display(binding: binding, customised: isCustomised, duplicated: isDuplicated)
    }
}

/// The AppKit control behind `ShortcutRecorderField`. A bordered, focusable
/// field that, while recording, becomes first responder and captures the next
/// key event — intercepting ⌘-equivalents in `performKeyEquivalent` so they
/// don't fire a menu item instead.
final class RecorderButton: NSView {
    var onCapture: ((KeyBinding) -> Void)?
    var onClear: (() -> Void)?

    /// A warm off-white for overridden shortcuts, and a burgundy outline for
    /// ones that share a binding with another command. Both are fixed (not
    /// system-derived) so "paper" reads as paper in either appearance.
    private static let paper = NSColor(srgbRed: 0.98, green: 0.95, blue: 0.86, alpha: 1)
    private static let paperInk = NSColor(srgbRed: 0.22, green: 0.18, blue: 0.11, alpha: 1)
    private static let burgundy = NSColor(srgbRed: 0.50, green: 0.11, blue: 0.18, alpha: 1)

    private var title = ""
    private var customised = false
    private var duplicated = false
    private var recording = false

    override var acceptsFirstResponder: Bool { recording }
    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 22) }

    func display(binding: KeyBinding, customised: Bool, duplicated: Bool) {
        title = binding.displayString
        self.customised = customised
        self.duplicated = duplicated
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if recording { endRecording() } else { beginRecording() }
    }

    private func beginRecording() {
        recording = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func endRecording() {
        recording = false
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        needsDisplay = true
        return true
    }

    /// While recording, ⌘-combos arrive here (menu key-equivalent dispatch runs
    /// before `keyDown`); swallow and capture them so no menu item fires.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        switch event.keyCode {
        case 53:                       // Escape — cancel, keep current binding
            endRecording()
        case 51, 117:                  // Delete / forward-delete — restore default
            onClear?()
            endRecording()
        default:
            if let chars = event.charactersIgnoringModifiers, let first = chars.first {
                // Letters normalise to lowercase with Shift carried in the
                // modifiers, matching AppKit's keyEquivalent convention; arrows
                // and punctuation pass through as typed.
                let key = first.isLetter ? String(first).lowercased() : String(first)
                onCapture?(KeyBinding(key: key, modifiers: event.modifierFlags))
            }
            endRecording()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)

        let fill: NSColor
        if recording {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.15)
        } else if customised {
            fill = Self.paper
        } else {
            fill = NSColor.controlBackgroundColor
        }
        fill.setFill()
        path.fill()

        let stroke: NSColor
        let width: CGFloat
        if recording {
            (stroke, width) = (.controlAccentColor, 2)
        } else if duplicated {
            (stroke, width) = (Self.burgundy, 2)
        } else {
            (stroke, width) = (.separatorColor, 1)
        }
        stroke.setStroke()
        path.lineWidth = width
        path.stroke()

        let text = recording ? "Type shortcut…" : (title.isEmpty ? "—" : title)
        let textColor: NSColor
        if recording {
            textColor = .controlAccentColor
        } else if customised {
            textColor = Self.paperInk       // keep contrast on the light paper fill
        } else {
            textColor = .labelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(
                ofSize: 12, weight: customised && !recording ? .semibold : .regular),
            .foregroundColor: textColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
