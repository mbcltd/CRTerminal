import Testing
@testable import TerminalCore

private func makeTerminal(columns: Int = 10, rows: Int = 4) -> Terminal {
    Terminal(columns: columns, rows: rows)
}

private extension Terminal {
    mutating func feed(_ text: String) {
        feed(Array(text.utf8))
    }

    var screen: [String] {
        (0..<state.rows).map { state.lineText($0) }
    }

    var allText: [String] {
        state.scrollback.map(TerminalState.text(of:)) + screen
    }
}

struct ReflowTests {
    @Test func softWrapSetsWrapFlag() {
        var t = makeTerminal(columns: 4, rows: 3)
        t.feed("abcdef")
        #expect(t.screen == ["abcd", "ef", ""])
        #expect(t.state.lineWrapped[0])
        #expect(!t.state.lineWrapped[1])
    }

    @Test func hardNewlineDoesNotSetWrapFlag() {
        var t = makeTerminal(columns: 4, rows: 3)
        t.feed("ab\r\ncd")
        #expect(!t.state.lineWrapped[0])
    }

    @Test func narrowingRewrapsLongLine() {
        var t = makeTerminal(columns: 10, rows: 4)
        t.feed("0123456789X")  // wraps onto row 1
        #expect(t.screen == ["0123456789", "X", "", ""])
        t.resize(columns: 5, rows: 4)
        #expect(t.allText == ["01234", "56789", "X", ""])
        #expect(t.state.cursor == Cursor(x: 1, y: 2))
    }

    @Test func wideningJoinsWrappedLines() {
        var t = makeTerminal(columns: 5, rows: 4)
        t.feed("0123456789X")
        #expect(t.screen == ["01234", "56789", "X", ""])
        t.resize(columns: 12, rows: 4)
        #expect(t.screen == ["0123456789X", "", "", ""])
        #expect(t.state.cursor == Cursor(x: 11, y: 0))
    }

    @Test func reflowRoundTripsThroughScrollback() {
        var t = makeTerminal(columns: 8, rows: 3)
        for i in 0..<6 {
            t.feed("line-\(i)\r\n")
        }
        let before = t.allText.filter { !$0.isEmpty }
        t.resize(columns: 4, rows: 3)
        t.resize(columns: 8, rows: 3)
        #expect(t.allText.filter { !$0.isEmpty } == before)
    }

    @Test func cursorColumnSurvivesRewrap() {
        var t = makeTerminal(columns: 10, rows: 4)
        t.feed("abcdefgh")  // cursor at column 8
        t.resize(columns: 5, rows: 4)
        // "abcdefgh" → "abcde" / "fgh"; cursor was after "h".
        #expect(t.state.cursor == Cursor(x: 3, y: 1))
        t.feed("Z")
        #expect(t.allText.first(where: { $0.hasPrefix("fgh") }) == "fghZ")
    }

    @Test func widePairsNeverSplit() {
        var t = makeTerminal(columns: 6, rows: 3)
        t.feed("ab漢字")  // 2 narrow + 2 wide = 6 cells exactly
        t.resize(columns: 5, rows: 3)
        // 漢 can't straddle columns 4→0; 字 moves down whole.
        let text = t.allText.joined(separator: "|")
        #expect(text.contains("漢"))
        #expect(text.contains("字"))
        for row in t.state.lines {
            var x = 0
            while x < row.count {
                if row[x].attributes.contains(.wide) {
                    #expect(x + 1 < row.count, "wide head at row edge")
                    #expect(row[x + 1].attributes.contains(.wideSpacer))
                    x += 2
                } else {
                    x += 1
                }
            }
        }
    }

    @Test func growingHeightPullsBackScrollback() {
        var t = makeTerminal(columns: 10, rows: 3)
        for i in 0..<5 {
            t.feed("row\(i)\r\n")
        }
        #expect(!t.state.scrollback.isEmpty)
        let scrollbackBefore = t.state.scrollback.count
        t.resize(columns: 10, rows: 6)
        #expect(t.state.scrollback.count == max(0, scrollbackBefore - 3))
        #expect(t.allText.contains("row0"))
    }

    @Test func shrinkingHeightEvictsToScrollback() {
        var t = makeTerminal(columns: 10, rows: 6)
        t.feed("a\r\nb\r\nc\r\nd")
        t.resize(columns: 10, rows: 2)
        #expect(t.screen == ["c", "d"])
        #expect(t.state.scrollback.map(TerminalState.text(of:)) == ["a", "b"])
        #expect(t.state.cursor.y == 1)
    }

    @Test func alternateScreenClipsButPrimaryReflows() {
        var t = makeTerminal(columns: 10, rows: 3)
        t.feed("0123456789X")  // soft-wrapped on primary
        t.feed("\u{1B}[?1049h")  // enter alt
        t.feed("ALT")
        t.resize(columns: 5, rows: 3)
        #expect(t.state.lineText(0) == "ALT")  // alt clipped, content kept
        t.feed("\u{1B}[?1049l")  // back to primary
        #expect(t.allText.contains("01234"))
        #expect(t.allText.contains("56789"))
    }

    @Test func eraseToEndOfLineBreaksWrap() {
        var t = makeTerminal(columns: 4, rows: 3)
        t.feed("abcdef")
        #expect(t.state.lineWrapped[0])
        t.feed("\u{1B}[1;3H\u{1B}[K")  // cursor row 0 col 2, erase to end
        #expect(!t.state.lineWrapped[0])
    }
}

struct HyperlinkTests {
    @Test func osc8AssignsAndEndsLinks() {
        var t = makeTerminal()
        t.feed("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\ off")
        let row = t.state.lines[0]
        #expect(row[0].link != 0)
        #expect(t.state.linkURL(row[0].link) == "https://example.com")
        #expect(row[3].link == row[0].link)
        #expect(row[5].link == 0)
    }

    @Test func sameURIReusesId() {
        var t = makeTerminal()
        t.feed("\u{1B}]8;;https://a\u{07}x\u{1B}]8;;\u{07} \u{1B}]8;;https://a\u{07}y\u{1B}]8;;\u{07}")
        #expect(t.state.lines[0][0].link == t.state.lines[0][2].link)
        #expect(t.state.linkTable.count == 1)
    }

    @Test func sgrResetDoesNotEndLink() {
        var t = makeTerminal()
        t.feed("\u{1B}]8;;https://a\u{07}\u{1B}[31mred\u{1B}[0mplain")
        #expect(t.state.lines[0][4].link != 0)
    }
}

struct ShellIntegrationTests {
    @Test func promptMarksRecordRows() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("\u{1B}]133;A\u{07}$ ls\r\n")
        t.feed("file\r\n")
        t.feed("\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}$ ")
        #expect(t.state.promptMarks.count == 2)
        #expect(t.state.promptMarks[0].row == 0)
        #expect(t.state.promptMarks[0].exitCode == 0)
        #expect(t.state.promptMarks[1].row == 2)
        #expect(t.state.promptMarks[1].exitCode == nil)
    }

    @Test func failedCommandRecordsExitCode() {
        var t = makeTerminal()
        t.feed("\u{1B}]133;A\u{07}$ false\r\n\u{1B}]133;D;1\u{07}")
        #expect(t.state.promptMarks.first?.exitCode == 1)
    }

    @Test func marksSurviveReflow() {
        var t = makeTerminal(columns: 10, rows: 4)
        t.feed("0123456789X\r\n")  // wrapped line above the prompt
        t.feed("\u{1B}]133;A\u{07}$ ")
        let markRow = t.state.promptMarks[0].row
        #expect(markRow == 2)  // two visual rows of wrapped output above
        t.resize(columns: 5, rows: 4)
        // The wrapped line now occupies 3 rows; the mark tracks the prompt.
        #expect(t.state.promptMarks[0].row == 3)
        let promptLine = t.state.absoluteLine(t.state.promptMarks[0].row)
        #expect(promptLine.map(TerminalState.text(of:)) == "$")
    }

    /// Mirrors the shell-integration byte order: prompt (A), end-of-prompt
    /// marker (B), the typed command, the echoed newline, then output (C).
    private func runCommand(
        _ t: inout Terminal, prompt: String = "$ ", command: String, exit: Int = 0
    ) {
        t.feed("\u{1B}]133;A\u{07}\(prompt)\u{1B}]133;B\u{07}\(command)\r\n\u{1B}]133;C\u{07}")
        t.feed("\u{1B}]133;D;\(exit)\u{07}")
    }

    @Test func capturesTypedCommand() {
        var t = makeTerminal(columns: 40, rows: 6)
        runCommand(&t, command: "git status", exit: 0)
        let mark = t.state.promptMarks.first
        #expect(mark?.command == "git status")
        #expect(mark?.exitCode == 0)
        #expect(mark?.sequence == 0)
    }

    @Test func capturesCommandDirectory() {
        var t = makeTerminal(columns: 40, rows: 6)
        t.feed("\u{1B}]7;file:///Users/me/dev\u{07}")
        runCommand(&t, command: "ls -la")
        #expect(t.state.promptMarks.first?.command == "ls -la")
        #expect(t.state.promptMarks.first?.directory == "/Users/me/dev")
    }

    @Test func emptyCommandIsNotCaptured() {
        var t = makeTerminal(columns: 40, rows: 6)
        // Enter pressed at an empty prompt: B then newline then C, no text.
        t.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}\r\n\u{1B}]133;C\u{07}")
        #expect(t.state.promptMarks.first?.command == nil)
    }

    @Test func sequencesAreMonotonic() {
        var t = makeTerminal(columns: 40, rows: 10)
        runCommand(&t, command: "one")
        runCommand(&t, command: "two")
        runCommand(&t, command: "three")
        let captured = t.state.promptMarks.compactMap(\.command)
        #expect(captured == ["one", "two", "three"])
        let sequences = t.state.promptMarks.compactMap(\.sequence)
        #expect(sequences == [0, 1, 2])
    }

    @Test func commandSurvivesSnapshotRoundTrip() {
        var t = makeTerminal(columns: 40, rows: 6)
        runCommand(&t, command: "make build", exit: 2)
        let restored = TerminalState(restoring: t.state.makeSnapshot())
        let mark = restored.promptMarks.first
        #expect(mark?.command == "make build")
        #expect(mark?.exitCode == 2)
    }
}

struct WorkingDirectoryTests {
    @Test func osc7TracksDirectory() {
        var t = makeTerminal()
        #expect(t.state.currentDirectory == nil)
        t.feed("\u{1B}]7;file://hostname/Users/dmb/dev\u{07}")
        #expect(t.state.currentDirectory == "/Users/dmb/dev")
        // A later cd updates it.
        t.feed("\u{1B}]7;file://hostname/tmp\u{07}")
        #expect(t.state.currentDirectory == "/tmp")
    }

    @Test func osc7AcceptsEmptyHostAndPercentEncoding() {
        var t = makeTerminal()
        t.feed("\u{1B}]7;file:///Users/dmb/my%20projects\u{07}")
        #expect(t.state.currentDirectory == "/Users/dmb/my projects")
    }

    @Test func osc7IgnoresMalformedPayload() {
        var t = makeTerminal()
        t.feed("\u{1B}]7;file://hostname/good\u{07}")
        t.feed("\u{1B}]7;garbage\u{07}")          // no path → keep the last good value
        #expect(t.state.currentDirectory == "/good")
        t.feed("\u{1B}]7;\u{07}")                 // empty → still kept
        #expect(t.state.currentDirectory == "/good")
    }

    @Test func fileURLPathParsing() {
        #expect(TerminalState.fileURLPath("file://host/a/b") == "/a/b")
        #expect(TerminalState.fileURLPath("file:///a/b") == "/a/b")
        #expect(TerminalState.fileURLPath("/bare/path") == "/bare/path")
        #expect(TerminalState.fileURLPath("file://host") == nil)
        #expect(TerminalState.fileURLPath("nonsense") == nil)
        #expect(TerminalState.fileURLPath("") == nil)
    }
}

struct NotificationTests {
    @Test func osc9Notifies() {
        var t = makeTerminal()
        t.feed("\u{1B}]9;build done\u{07}")
        let notes = t.drainNotifications()
        #expect(notes == [TerminalNotification(title: "", body: "build done")])
        #expect(t.drainNotifications().isEmpty)
    }

    @Test func osc777Notifies() {
        var t = makeTerminal()
        t.feed("\u{1B}]777;notify;Build;it passed\u{1B}\\")
        #expect(t.drainNotifications() == [
            TerminalNotification(title: "Build", body: "it passed")
        ])
    }
}

struct ProgressTests {
    @Test func reportsAndClears() {
        var t = makeTerminal()
        t.feed("\u{1B}]9;4;1;50\u{07}")
        #expect(t.state.progress == ProgressReport(state: .normal, percent: 50))
        #expect(t.drainNotifications().isEmpty)  // not a notification
        t.feed("\u{1B}]9;4;0;0\u{07}")
        #expect(t.state.progress == nil)
    }

    @Test func clampsPercent() {
        var t = makeTerminal()
        t.feed("\u{1B}]9;4;1;250\u{07}")
        #expect(t.state.progress?.percent == 100)
        t.feed("\u{1B}]9;4;1;-3\u{07}")
        #expect(t.state.progress?.percent == 0)
    }

    @Test func errorAndPausedKeepLastPercent() {
        var t = makeTerminal()
        t.feed("\u{1B}]9;4;1;70\u{07}")
        t.feed("\u{1B}]9;4;2\u{07}")
        #expect(t.state.progress == ProgressReport(state: .error, percent: 70))
        t.feed("\u{1B}]9;4;4\u{07}")
        #expect(t.state.progress == ProgressReport(state: .paused, percent: 70))
    }

    @Test func indeterminateIgnoresPercent() {
        var t = makeTerminal()
        t.feed("\u{1B}]9;4;3;55\u{07}")
        #expect(t.state.progress == ProgressReport(state: .indeterminate, percent: 0))
    }

    @Test func malformedPayloadsAreSafe() {
        var t = makeTerminal()
        t.feed("\u{1B}]9;4;1;50\u{07}")
        t.feed("\u{1B}]9;4;9;10\u{07}")  // unknown state: ignored
        #expect(t.state.progress == ProgressReport(state: .normal, percent: 50))
        t.feed("\u{1B}]9;4;junk;10\u{07}")  // garbage state: clears
        #expect(t.state.progress == nil)
        t.feed("\u{1B}]9;4\u{07}")  // bare "4": clears, stays nil
        #expect(t.state.progress == nil)
        t.feed("\u{1B}]9;4;1;abc\u{07}")  // garbage percent: 0
        #expect(t.state.progress == ProgressReport(state: .normal, percent: 0))
    }

    @Test func nonProgressOSC9StillNotifies() {
        var t = makeTerminal()
        t.feed("\u{1B}]9;42 done\u{07}")  // "4" not followed by ";"
        #expect(t.drainNotifications() == [
            TerminalNotification(title: "", body: "42 done")
        ])
        #expect(t.state.progress == nil)
    }

    @Test func promptStartClearsStaleProgress() {
        var t = makeTerminal()
        t.feed("\u{1B}]9;4;1;80\u{07}")
        t.feed("\u{1B}]133;A\u{07}$ ")
        #expect(t.state.progress == nil)
    }

    @Test func resetClearsProgress() {
        var t = makeTerminal()
        t.feed("\u{1B}]9;4;1;80\u{07}")
        t.feed("\u{1B}c")  // RIS
        #expect(t.state.progress == nil)
    }

    @Test func progressBumpsGeneration() {
        var t = makeTerminal()
        t.feed("\u{1B}]9;4;1;10\u{07}")
        let before = t.state.generation
        t.feed("\u{1B}]9;4;1;20\u{07}")
        #expect(t.state.generation > before)
        let unchanged = t.state.generation
        t.feed("\u{1B}]9;4;1;20\u{07}")  // same report: no bump
        #expect(t.state.generation == unchanged)
    }
}

struct KittyKeyboardTests {
    @Test func pushPopAndQuery() {
        var t = makeTerminal()
        t.feed("\u{1B}[>1u")
        #expect(t.state.modes.kittyKeyboardFlags == .disambiguate)
        t.feed("\u{1B}[?u")
        #expect(t.drainResponses() == Array("\u{1B}[?1u".utf8))
        t.feed("\u{1B}[<u")
        #expect(t.state.modes.kittyKeyboardFlags == [])
        t.feed("\u{1B}[<5u")  // over-pop is safe
        #expect(t.state.modes.kittyKeyboardFlags == [])
    }

    @Test func setClearBits() {
        var t = makeTerminal()
        t.feed("\u{1B}[=1;1u")
        #expect(t.state.modes.kittyKeyboardFlags == .disambiguate)
        t.feed("\u{1B}[=1;3u")
        #expect(t.state.modes.kittyKeyboardFlags == [])
    }

    @Test func encoderDisambiguatesEscape() {
        #expect(KeyEncoder.encode(.escape) == [0x1B])
        #expect(KeyEncoder.encode(.escape, kittyFlags: .disambiguate)
                == Array("\u{1B}[27u".utf8))
        // Enter/Tab/Backspace stay legacy unless modified.
        #expect(KeyEncoder.encode(.enter, kittyFlags: .disambiguate) == [0x0D])
        #expect(KeyEncoder.encode(.tab, kittyFlags: .disambiguate) == [0x09])
        #expect(KeyEncoder.encode(.backspace, kittyFlags: .disambiguate) == [0x7F])
        #expect(KeyEncoder.encode(.enter, modifiers: [.shift], kittyFlags: .disambiguate)
                == Array("\u{1B}[13;2u".utf8))
    }

    @Test func encoderMetaEnter() {
        // Bare Enter is CR; Option (Meta) prefixes ESC so apps can tell
        // Meta+Enter from Return (Claude Code uses it for a literal newline).
        #expect(KeyEncoder.encode(.enter) == [0x0D])
        #expect(KeyEncoder.encode(.enter, modifiers: [.option]) == [0x1B, 0x0D])
        // Under the kitty protocol it disambiguates via CSI u instead.
        #expect(KeyEncoder.encode(.enter, modifiers: [.option], kittyFlags: .disambiguate)
                == Array("\u{1B}[13;3u".utf8))
    }

    @Test func encoderDisambiguatesCtrlKeys() {
        #expect(KeyEncoder.encodeCharacter("i", modifiers: [.control], kittyFlags: [])
                == nil)
        #expect(KeyEncoder.encodeCharacter(
            "i", modifiers: [.control], kittyFlags: .disambiguate)
                == Array("\u{1B}[105;5u".utf8))
        #expect(KeyEncoder.encodeCharacter(
            "a", modifiers: [], kittyFlags: .disambiguate) == nil)
    }

    @Test func resetClearsKittyState() {
        var t = makeTerminal()
        t.feed("\u{1B}[>1u\u{1B}c")  // push then RIS
        #expect(t.state.modes.kittyKeyboardFlags == [])
        t.feed("\u{1B}[<u")
        #expect(t.state.modes.kittyKeyboardFlags == [])
    }

    // MARK: Higher progressive-enhancement levels (issue #26)

    @Test func setFlagsAssignsAndQueryReports() {
        var t = makeTerminal()
        t.feed("\u{1B}[=5;1u") // assign disambiguate + reportAlternateKeys (0b101)
        #expect(t.state.modes.kittyKeyboardFlags == [.disambiguate, .reportAlternateKeys])
        t.feed("\u{1B}[?u")
        #expect(t.drainResponses() == Array("\u{1B}[?5u".utf8))
    }

    @Test func setFlagsAddAndRemoveBits() {
        var t = makeTerminal()
        t.feed("\u{1B}[=1;1u")      // assign 0b1
        t.feed("\u{1B}[=2;2u")      // add 0b10
        #expect(t.state.modes.kittyKeyboardFlags == [.disambiguate, .reportEventTypes])
        t.feed("\u{1B}[=1;3u")      // remove 0b1
        #expect(t.state.modes.kittyKeyboardFlags == [.reportEventTypes])
    }

    @Test func pushPopRestoresPriorFlags() {
        var t = makeTerminal()
        t.feed("\u{1B}[=5;1u")      // current = 0b101
        t.feed("\u{1B}[>26u")       // push, adopt 0b11010 (all but disambiguate)
        #expect(t.state.modes.kittyKeyboardFlags.rawValue == 0b11010)
        t.feed("\u{1B}[<u")         // pop
        #expect(t.state.modes.kittyKeyboardFlags.rawValue == 0b101)
    }

    @Test func flagsResetAndRestoreAcrossAlternateScreen() {
        var t = makeTerminal()
        t.feed("\u{1B}[>5u")        // main screen: 0b101
        t.feed("\u{1B}[?1049h")     // enter alternate screen
        #expect(t.state.modes.kittyKeyboardFlags == []) // fresh stack
        t.feed("\u{1B}[>2u")        // alt screen sets its own flags
        #expect(t.state.modes.kittyKeyboardFlags == .reportEventTypes)
        t.feed("\u{1B}[?1049l")     // leave: main flags restored
        #expect(t.state.modes.kittyKeyboardFlags.rawValue == 0b101)
    }

    @Test func encoderReportsEventTypes() {
        // Press vs release of the same key encode distinct :1 / :3 event types.
        let flags: KittyKeyboardFlags = [.disambiguate, .reportEventTypes]
        #expect(KeyEncoder.encode(.escape, kittyFlags: flags, eventType: .press)
                == Array("\u{1B}[27;1:1u".utf8))
        #expect(KeyEncoder.encode(.escape, kittyFlags: flags, eventType: .release)
                == Array("\u{1B}[27;1:3u".utf8))
        // Functional keys gain the event field too (Up, repeat).
        #expect(KeyEncoder.encode(.up, kittyFlags: flags, eventType: .repeat)
                == Array("\u{1B}[1;1:2A".utf8))
    }

    @Test func encoderReportsAllKeysAsEscapeCodes() {
        // Plain 'a' becomes a CSI u sequence rather than the byte 0x61.
        #expect(KeyEncoder.encodeCharacter(
            "a", modifiers: [], kittyFlags: .reportAllKeysAsEscapeCodes)
                == Array("\u{1B}[97u".utf8))
        // Enter / Tab / Backspace report as escape codes at this level.
        let all: KittyKeyboardFlags = .reportAllKeysAsEscapeCodes
        #expect(KeyEncoder.encode(.enter, kittyFlags: all) == Array("\u{1B}[13u".utf8))
        #expect(KeyEncoder.encode(.tab, kittyFlags: all) == Array("\u{1B}[9u".utf8))
        #expect(KeyEncoder.encode(.backspace, kittyFlags: all) == Array("\u{1B}[127u".utf8))
    }

    @Test func encoderReportsAlternateKeys() {
        // Shift+a: base 97, shifted 65, with the shift modifier.
        let flags: KittyKeyboardFlags = [.reportAllKeysAsEscapeCodes, .reportAlternateKeys]
        #expect(KeyEncoder.encodeCharacter(
            "a", modifiers: [.shift], kittyFlags: flags, shiftedScalar: "A")
                == Array("\u{1B}[97:65;2u".utf8))
    }

    @Test func encoderReportsAssociatedText() {
        // The text field is appended as codepoints (here 'a' = 97).
        let flags: KittyKeyboardFlags = [.reportAllKeysAsEscapeCodes, .reportAssociatedText]
        #expect(KeyEncoder.encodeCharacter(
            "a", modifiers: [], kittyFlags: flags, text: "a")
                == Array("\u{1B}[97;;97u".utf8))
    }

    @Test func encoderRegressionWithoutHigherFlags() {
        // With [] and disambiguate-only, output is byte-identical to before.
        #expect(KeyEncoder.encode(.up) == Array("\u{1B}[A".utf8))
        #expect(KeyEncoder.encode(.up, modifiers: [.shift]) == Array("\u{1B}[1;2A".utf8))
        #expect(KeyEncoder.encode(.escape, kittyFlags: .disambiguate)
                == Array("\u{1B}[27u".utf8))
        #expect(KeyEncoder.encode(.enter, kittyFlags: .disambiguate) == [0x0D])
        #expect(KeyEncoder.encodeCharacter("a", modifiers: [], kittyFlags: .disambiguate) == nil)
        #expect(KeyEncoder.encodeCharacter(
            "i", modifiers: [.control], kittyFlags: .disambiguate)
                == Array("\u{1B}[105;5u".utf8))
    }
}

struct SearchTests {
    @Test func findsMostRecentMatchFirst() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("alpha\r\nbeta\r\nalpha again\r\n")
        let hit = t.state.search(for: "alpha")
        #expect(hit?.anchor == SelectionPoint(row: 2, column: 0))
        #expect(hit?.head == SelectionPoint(row: 2, column: 4)) // inclusive last cell
        let earlier = t.state.search(for: "alpha", from: hit?.anchor)
        #expect(earlier?.anchor == SelectionPoint(row: 0, column: 0))
    }

    @Test func searchIsCaseInsensitiveForASCII() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("Hello World")
        #expect(t.state.search(for: "hello world") != nil)
        #expect(t.state.search(for: "WORLD")?.anchor.column == 6)
    }

    @Test func forwardSearchAdvances() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("x match y\r\nmatch two")
        let first = t.state.search(
            for: "match", from: SelectionPoint(row: 0, column: -1), backward: false)
        #expect(first?.anchor == SelectionPoint(row: 0, column: 2))
        let second = t.state.search(for: "match", from: first?.anchor, backward: false)
        #expect(second?.anchor == SelectionPoint(row: 1, column: 0))
    }

    @Test func searchesScrollback() {
        var t = makeTerminal(columns: 10, rows: 2)
        t.feed("needle\r\n\r\n\r\n\r\n")
        #expect(t.state.scrollback.count > 0)
        let hit = t.state.search(for: "needle")
        #expect(hit?.anchor.row == 0)
    }

    @Test func missReturnsNil() {
        var t = makeTerminal()
        t.feed("haystack")
        #expect(t.state.search(for: "zebra") == nil)
        #expect(t.state.search(for: "") == nil)
    }

    @Test func allMatchesAreInDocumentOrder() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("alpha\r\nbeta\r\nalpha again\r\n")
        let hits = t.state.allMatches(for: "alpha")
        #expect(hits.count == 2)
        #expect(hits[0].anchor == SelectionPoint(row: 0, column: 0))
        #expect(hits[1].anchor == SelectionPoint(row: 2, column: 0))
    }

    @Test func allMatchesFindsRepeatsWithinARow() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("aabaab")
        let hits = t.state.allMatches(for: "aa")
        // Non-overlapping: columns 0 and 3, not the overlap at column 1.
        #expect(hits.map(\.anchor.column) == [0, 3])
        #expect(hits.allSatisfy { $0.anchor.row == 0 })
    }

    @Test func allMatchesIsCaseInsensitiveAndSpansScrollback() {
        var t = makeTerminal(columns: 10, rows: 2)
        t.feed("Auth\r\nxauthx\r\n\r\n\r\n")
        #expect(t.state.scrollback.count > 0)
        let hits = t.state.allMatches(for: "AUTH")
        #expect(hits.count == 2)
        #expect(hits.first?.anchor.row == 0)
    }

    @Test func allMatchesEmptyOrMissReturnsEmpty() {
        var t = makeTerminal()
        t.feed("haystack")
        #expect(t.state.allMatches(for: "zebra").isEmpty)
        #expect(t.state.allMatches(for: "").isEmpty)
    }

    @Test func allMatchesEndColumnSpansWideGlyphs() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("a中b") // 中 is wide: occupies columns 1-2, spacer at 2
        let hits = t.state.allMatches(for: "中")
        #expect(hits.count == 1)
        #expect(hits[0].anchor.column == 1)
        #expect(hits[0].head.column == 2) // inclusive: the wide glyph's spacer cell
    }

    // MARK: SearchOptions (#43: case / whole-word / regex chips)

    @Test func caseSensitiveDistinguishesCase() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("Auth auth AUTH")
        let opts = SearchOptions(caseSensitive: true)
        let hits = t.state.allMatches(for: "auth", options: opts)
        #expect(hits.count == 1) // only the lowercase middle word
        #expect(hits[0].anchor.column == 5)
    }

    @Test func wholeWordRejectsSubstrings() {
        var t = makeTerminal(columns: 30, rows: 4)
        t.feed("cat category scatter cat")
        let opts = SearchOptions(wholeWord: true)
        let hits = t.state.allMatches(for: "cat", options: opts)
        // Matches the two standalone "cat"s, not "category" or "scatter".
        #expect(hits.map(\.anchor.column) == [0, 21])
    }

    @Test func wholeWordHonoursUnderscoreBoundaries() {
        var t = makeTerminal(columns: 30, rows: 4)
        t.feed("foo foo_bar")
        let opts = SearchOptions(wholeWord: true)
        let hits = t.state.allMatches(for: "foo", options: opts)
        // The underscore is a word character, so "foo_bar" is not a boundary.
        #expect(hits.count == 1)
        #expect(hits[0].anchor.column == 0)
    }

    @Test func regexMatchesAndMapsColumns() {
        var t = makeTerminal(columns: 30, rows: 4)
        t.feed("err 12 warn 345 ok")
        let opts = SearchOptions(regex: true)
        let hits = t.state.allMatches(for: "[0-9]+", options: opts)
        #expect(hits.count == 2)
        #expect(hits[0].anchor.column == 4)
        #expect(hits[0].head.column == 5) // "12", inclusive last cell
        #expect(hits[1].anchor.column == 12)
        #expect(hits[1].head.column == 14) // "345", inclusive last cell
    }

    @Test func regexIsCaseInsensitiveByDefault() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("Error ERROR error")
        let insensitive = t.state.allMatches(for: "error", options: SearchOptions(regex: true))
        #expect(insensitive.count == 3)
        let sensitive = t.state.allMatches(
            for: "error", options: SearchOptions(caseSensitive: true, regex: true))
        #expect(sensitive.count == 1)
        #expect(sensitive[0].anchor.column == 12)
    }

    @Test func regexEndColumnSpansWideGlyphs() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("a中b") // 中 is wide
        // `.` matches every (space-padded) cell; check the leading three to
        // confirm the wide glyph's end column steps past its spacer.
        let hits = t.state.allMatches(for: ".", options: SearchOptions(regex: true))
        #expect(hits.prefix(3).map(\.anchor.column) == [0, 1, 3]) // a, 中, b
        #expect(hits.prefix(3).map(\.head.column) == [0, 2, 3]) // inclusive last cell
    }

    @Test func regexWholeWordWrapsBoundaries() {
        var t = makeTerminal(columns: 30, rows: 4)
        t.feed("log logger relog")
        let opts = SearchOptions(wholeWord: true, regex: true)
        let hits = t.state.allMatches(for: "log", options: opts)
        #expect(hits.count == 1)
        #expect(hits[0].anchor.column == 0)
    }

    @Test func badRegexCompilesToNoPattern() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("anything")
        let opts = SearchOptions(regex: true)
        #expect(SearchPattern("[unclosed", options: opts) == nil)
        // The string convenience entry points fall back to no matches.
        #expect(t.state.allMatches(for: "[unclosed", options: opts).isEmpty)
        #expect(t.state.search(for: "[unclosed", options: opts) == nil)
    }

    @Test func compiledPatternIsReusable() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("a1 b2 c3")
        let pattern = SearchPattern("[a-z][0-9]", options: SearchOptions(regex: true))
        #expect(pattern != nil)
        #expect(t.state.allMatches(pattern: pattern!).count == 3)
        #expect(t.state.search(pattern: pattern!)?.anchor.column == 6) // last: c3
    }
}
