import AppKit
import Testing
import TerminalCore
@testable import CRTerminal

/// The legacy key path encodes navigation keys straight from the `NSEvent`
/// so their modifiers survive. Routed through the input context they came
/// back as text-system selectors, and ⌥↑ (`moveToBeginningOfParagraph:`)
/// was silently dropped — Codex's "⌥↑ to answer" did nothing.
struct NavigationKeyTests {
    private static func keyEvent(
        characters: String, ignoringModifiers: String? = nil, keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: ignoringModifiers ?? characters,
            isARepeat: isRepeat, keyCode: keyCode)!
    }

    /// An arrow key as AppKit delivers it: the private-use scalar in both
    /// character fields, with the function and numeric-pad flags set.
    private static func arrow(
        _ scalar: UInt32, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false
    ) -> NSEvent {
        keyEvent(
            characters: String(UnicodeScalar(scalar)!), keyCode: keyCode,
            modifiers: modifiers.union([.function, .numericPad]), isRepeat: isRepeat)
    }

    private static func up(_ m: NSEvent.ModifierFlags = [], isRepeat: Bool = false) -> NSEvent {
        arrow(0xF700, keyCode: 126, m, isRepeat: isRepeat)
    }
    private static func down(_ m: NSEvent.ModifierFlags = []) -> NSEvent { arrow(0xF701, keyCode: 125, m) }
    private static func left(_ m: NSEvent.ModifierFlags = []) -> NSEvent { arrow(0xF702, keyCode: 123, m) }
    private static func right(_ m: NSEvent.ModifierFlags = []) -> NSEvent { arrow(0xF703, keyCode: 124, m) }

    private static var kittyModes: TerminalModes {
        var modes = TerminalModes()
        modes.kittyKeyboardFlags = [.disambiguate, .reportEventTypes] // what Codex asks for
        return modes
    }

    @MainActor
    private static func bytes(_ event: NSEvent, modes: TerminalModes = TerminalModes()) -> String? {
        TerminalView.navigationBytes(for: event, modes: modes)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    @Test @MainActor func optionArrowsKeepTheirModifier() {
        #expect(Self.bytes(Self.up([.option])) == "\u{1B}[1;3A")
        #expect(Self.bytes(Self.down([.option, .shift])) == "\u{1B}[1;4B")
        #expect(Self.bytes(Self.up([.control])) == "\u{1B}[1;5A")
        #expect(Self.bytes(Self.up([.option]), modes: Self.kittyModes) == "\u{1B}[1;3:1A")
    }

    @Test @MainActor func optionLeftAndRightAreWordMotionsUnlessKittyIsOn() {
        #expect(Self.bytes(Self.left([.option])) == "\u{1B}b")
        #expect(Self.bytes(Self.right([.option])) == "\u{1B}f")
        #expect(Self.bytes(Self.left([.option, .shift])) == "\u{1B}[1;4D")
        #expect(Self.bytes(Self.left([.option]), modes: Self.kittyModes) == "\u{1B}[1;3:1D")
    }

    @Test @MainActor func plainArrowsFollowCursorKeyMode() {
        #expect(Self.bytes(Self.up()) == "\u{1B}[A")
        var application = TerminalModes()
        application.applicationCursorKeys = true
        #expect(Self.bytes(Self.up(), modes: application) == "\u{1B}OA")
        #expect(Self.bytes(Self.up([.shift])) == "\u{1B}[1;2A")
    }

    @Test @MainActor func repeatsReportTheirEventTypeUnderKitty() {
        #expect(Self.bytes(Self.up(isRepeat: true), modes: Self.kittyModes) == "\u{1B}[1;1:2A")
        // Legacy encodings have nowhere to put an event type.
        #expect(Self.bytes(Self.up(isRepeat: true)) == "\u{1B}[A")
    }

    @Test @MainActor func editingAndFunctionKeysAreCovered() {
        #expect(Self.bytes(Self.keyEvent(characters: "\u{F728}", keyCode: 117, modifiers: [.function]))
            == "\u{1B}[3~") // Forward Delete
        #expect(Self.bytes(Self.keyEvent(characters: "\u{F72C}", keyCode: 116, modifiers: [.function]))
            == "\u{1B}[5~") // Page Up
        #expect(Self.bytes(Self.keyEvent(characters: "\u{F729}", keyCode: 115, modifiers: [.function]))
            == "\u{1B}[H") // Home
        #expect(Self.bytes(Self.keyEvent(characters: "\u{F708}", keyCode: 96, modifiers: [.function]))
            == "\u{1B}[15~") // F5
        #expect(Self.bytes(Self.keyEvent(characters: "\u{F708}", keyCode: 96, modifiers: [.function, .shift]))
            == "\u{1B}[15;2~")
    }

    @Test @MainActor func otherKeysStayWithTheInputContext() {
        // Text — even ⌥-text, which may be a dead key mid-composition.
        #expect(Self.bytes(Self.keyEvent(
            characters: "å", ignoringModifiers: "a", keyCode: 0, modifiers: [.option])) == nil)
        #expect(Self.bytes(Self.keyEvent(characters: "\r", keyCode: 36)) == nil)
        #expect(Self.bytes(Self.keyEvent(characters: "\u{1B}", keyCode: 53)) == nil)
        // ⌘-arrows are the text system's Home/End (and menu equivalents first).
        #expect(Self.bytes(Self.up([.command])) == nil)
    }
}

/// End to end through `keyDown`: the event must reach the session as the
/// encoded bytes, not be handed to the input context and dropped.
struct NavigationKeyDeliveryTests {
    @Test @MainActor func optionUpReachesTheShell() throws {
        // A scripted "shell" (typing into the real $SHELL isn't CI-safe) that
        // just sits in canonical mode: the line discipline echoes what we
        // type, rendering ESC as ^[ (echoctl), so the bytes show up as text.
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("crt-option-up-probe.sh").path
        try "#!/bin/sh\nstty echo echoctl icanon\nexec cat\n"
            .write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script)
        let session = try TerminalSession(columns: 80, rows: 24, shell: script)
        defer { session.terminate() }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.session = session

        let optionUp = NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: [.option, .function, .numericPad], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{F700}",
            charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126)!
        view.keyDown(with: optionUp)

        var line = session.snapshot.lineText(0)
        for _ in 0..<500 where !line.contains("^[[1;3A") {
            usleep(10_000)
            line = session.snapshot.lineText(0)
        }
        #expect(line == "^[[1;3A")
    }
}
