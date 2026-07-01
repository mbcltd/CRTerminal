import AppKit
import Foundation
import Testing
@testable import CRTerminal

struct KeyBindingTests {
    @Test func jsonRoundTrip() throws {
        let binding = KeyBinding(key: "d", modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(KeyBinding.self, from: data)
        #expect(decoded == binding)
    }

    @Test func stripsIrrelevantModifiers() {
        // capsLock/function must not survive — they'd break equality and
        // conflict checks.
        let binding = KeyBinding(key: "k", modifiers: [.command, .capsLock, .function])
        #expect(binding.flags == [.command])
    }

    @Test func requiresCommandToFire() {
        #expect(KeyBinding(key: "e", modifiers: [.command]).includesCommand)
        #expect(!KeyBinding(key: "e", modifiers: [.control, .shift]).includesCommand)
    }

    @Test func conflictsIgnoreLetterCase() {
        let a = KeyBinding(key: "d", modifiers: [.command])
        let b = KeyBinding(key: "D", modifiers: [.command])
        let c = KeyBinding(key: "d", modifiers: [.command, .shift])
        #expect(a.conflicts(with: b))
        #expect(!a.conflicts(with: c))
    }

    @Test func displayStringUsesStandardGlyphOrder() {
        let binding = KeyBinding(key: "k", modifiers: [.command, .shift, .option, .control])
        #expect(binding.displayString == "⌃⌥⇧⌘K")
    }

    @Test func displayStringRendersArrows() {
        let up = KeyBinding(
            key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command])
        let down = KeyBinding(
            key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.command])
        #expect(up.displayString == "⌘↑")
        #expect(down.displayString == "⌘↓")
    }
}

struct AppCommandBindingTests {
    /// Guards the extraction of the hardcoded shortcuts into `AppCommand`: every
    /// default must render as the shortcut it replaced in the old menu.
    @Test func defaultsMatchLegacyMenuShortcuts() {
        let expected: [AppCommand: String] = [
            .newWindow: "⌘N",
            .newSession: "⌘T",
            .nextSession: "⇧⌘]",
            .previousSession: "⇧⌘[",
            .jumpToSession: "⌘K",
            .searchCommandHistory: "⇧⌘K",
            .searchAllCommandHistory: "⌥⌘K",
            .clear: "⌘L",
            .splitRight: "⌘D",
            .splitDown: "⇧⌘D",
            .closePane: "⌘W",
            .find: "⌘F",
            .findNext: "⌘G",
            .findPrevious: "⇧⌘G",
            .previousPrompt: "⌘↑",
            .nextPrompt: "⌘↓",
        ]
        for command in AppCommand.allCases {
            #expect(command.defaultBinding.displayString == expected[command])
        }
    }

    /// Every factory default must include ⌘, or it would swallow bare keys.
    @Test func everyDefaultIncludesCommand() {
        for command in AppCommand.allCases {
            #expect(command.defaultBinding.includesCommand)
        }
    }

    /// No two commands may ship with the same default shortcut.
    @Test func defaultsAreUnique() {
        let commands = AppCommand.allCases
        for i in commands.indices {
            for j in commands.indices where j > i {
                #expect(
                    !commands[i].defaultBinding.conflicts(with: commands[j].defaultBinding),
                    "\(commands[i]) and \(commands[j]) share a default shortcut")
            }
        }
    }

    @Test func bindingPrefersOverrideThenDefault() {
        var settings = TerminalSettings()
        #expect(settings.binding(for: .splitRight) == AppCommand.splitRight.defaultBinding)
        let custom = KeyBinding(key: "e", modifiers: [.command])
        settings.keyBindings[AppCommand.splitRight.rawValue] = custom
        #expect(settings.binding(for: .splitRight) == custom)
        // Unrelated commands still resolve to their defaults.
        #expect(settings.binding(for: .find) == AppCommand.find.defaultBinding)
    }

    /// A settings blob written before keybindings existed must still decode,
    /// leaving every command on its default (forward/backward-compat contract).
    @Test func decodesLegacyBlobWithoutKeyBindings() throws {
        let legacy = """
        {"fontSize":15,"presetName":"Dark","scrollbackLines":5000,"ligatures":true}
        """
        let decoded = try JSONDecoder().decode(
            TerminalSettings.self, from: Data(legacy.utf8))
        #expect(decoded.keyBindings.isEmpty)
        #expect(decoded.binding(for: .jumpToSession) == AppCommand.jumpToSession.defaultBinding)
        #expect(decoded.fontSize == 15)
    }
}
