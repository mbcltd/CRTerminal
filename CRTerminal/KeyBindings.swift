import AppKit

/// A single editable keyboard shortcut: the `keyEquivalent` character plus its
/// modifier flags. Stored device-independently so it round-trips through JSON in
/// `TerminalSettings` and drives both the menu (`AppDelegate.makeMainMenu`) and
/// the Settings recorder.
struct KeyBinding: Codable, Equatable {
    /// The `NSMenuItem.keyEquivalent` character — a lowercased letter ("d"),
    /// a punctuation key ("]"), or an arrow function-key scalar. Shift lives in
    /// `modifiers`, never in the case of this character (matching AppKit's
    /// convention for menu key equivalents).
    var key: String
    /// `NSEvent.ModifierFlags` raw value, restricted to ⌘⇧⌥⌃.
    var modifiers: UInt

    /// The only modifiers a shortcut may carry; everything else (capsLock,
    /// function, numericPad…) is stripped so equality and conflict checks stay
    /// meaningful.
    static let relevantModifiers: NSEvent.ModifierFlags =
        [.command, .shift, .option, .control]

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// A menu shortcut only fires when it carries ⌘; without it the equivalent
    /// would swallow bare keystrokes headed for the shell. The recorder rejects
    /// anything this returns false for.
    var includesCommand: Bool { flags.contains(.command) }

    /// True when two bindings would collide as menu shortcuts (same key,
    /// ignoring letter case, and identical modifiers).
    func conflicts(with other: KeyBinding) -> Bool {
        key.lowercased() == other.key.lowercased() && flags == other.flags
    }

    /// The shortcut rendered with the standard macOS glyphs (⌃⌥⇧⌘ then the key),
    /// used in the Settings rows and for the recorder's live display.
    var displayString: String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        result += Self.keyGlyph(key)
        return result
    }

    /// Renders a `keyEquivalent` character as its display glyph: named symbols
    /// for arrows and whitespace, uppercased letters otherwise.
    static func keyGlyph(_ key: String) -> String {
        switch key {
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): return "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): return "↓"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): return "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): return "→"
        case " ": return "Space"
        case "\r": return "↩"
        case "\u{1b}": return "⎋"
        case "\u{7f}", "\u{8}": return "⌫"
        case "\t": return "⇥"
        default: return key.uppercased()
        }
    }
}

/// The app-specific commands whose shortcuts the user can rebind. macOS-standard
/// items (Copy/Paste/Select All/Quit/Hide/Minimize) and the index-derived
/// families (⌘1–9 sessions, ⌃⌘1–9 presets) are deliberately excluded — they stay
/// hardcoded in `AppDelegate.makeMainMenu`.
///
/// `title` matches the menu item verbatim and `defaultBinding` is the single
/// source of truth for the factory shortcut (the menu no longer hardcodes it).
/// The selector and target for each command live in `AppDelegate` — several of
/// those methods are `private`, so the mapping stays where they're visible.
enum AppCommand: String, CaseIterable, Codable {
    case newWindow, newSession, nextSession, previousSession
    case jumpToSession, searchCommandHistory, searchAllCommandHistory
    case clear, splitRight, splitDown, closePane
    case find, findNext, findPrevious
    case previousPrompt, nextPrompt

    /// The submenu a command lives under; used to group and order the rows in
    /// the Settings editor.
    enum Section: String, CaseIterable {
        case shell, edit, view
        var title: String {
            switch self {
            case .shell: return "Shell"
            case .edit: return "Edit"
            case .view: return "View"
            }
        }
    }

    var title: String {
        switch self {
        case .newWindow: return "New Window"
        case .newSession: return "New Session"
        case .nextSession: return "Next Session"
        case .previousSession: return "Previous Session"
        case .jumpToSession: return "Jump to Session…"
        case .searchCommandHistory: return "Search Command History…"
        case .searchAllCommandHistory: return "Search All Command History…"
        case .clear: return "Clear"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
        case .closePane: return "Close Pane"
        case .find: return "Find…"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .previousPrompt: return "Jump to Previous Prompt"
        case .nextPrompt: return "Jump to Next Prompt"
        }
    }

    var section: Section {
        switch self {
        case .newWindow, .newSession, .nextSession, .previousSession,
             .jumpToSession, .searchCommandHistory, .searchAllCommandHistory,
             .clear, .splitRight, .splitDown, .closePane:
            return .shell
        case .find, .findNext, .findPrevious:
            return .edit
        case .previousPrompt, .nextPrompt:
            return .view
        }
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .newWindow: return KeyBinding(key: "n", modifiers: [.command])
        case .newSession: return KeyBinding(key: "t", modifiers: [.command])
        case .nextSession: return KeyBinding(key: "]", modifiers: [.command, .shift])
        case .previousSession: return KeyBinding(key: "[", modifiers: [.command, .shift])
        case .jumpToSession: return KeyBinding(key: "k", modifiers: [.command])
        case .searchCommandHistory:
            return KeyBinding(key: "k", modifiers: [.command, .shift])
        case .searchAllCommandHistory:
            return KeyBinding(key: "k", modifiers: [.command, .option])
        case .clear: return KeyBinding(key: "l", modifiers: [.command])
        case .splitRight: return KeyBinding(key: "d", modifiers: [.command])
        case .splitDown: return KeyBinding(key: "d", modifiers: [.command, .shift])
        case .closePane: return KeyBinding(key: "w", modifiers: [.command])
        case .find: return KeyBinding(key: "f", modifiers: [.command])
        case .findNext: return KeyBinding(key: "g", modifiers: [.command])
        case .findPrevious: return KeyBinding(key: "g", modifiers: [.command, .shift])
        case .previousPrompt:
            return KeyBinding(
                key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command])
        case .nextPrompt:
            return KeyBinding(
                key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.command])
        }
    }
}
