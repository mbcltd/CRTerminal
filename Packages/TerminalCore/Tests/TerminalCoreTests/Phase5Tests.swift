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
}

struct SearchTests {
    @Test func findsMostRecentMatchFirst() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("alpha\r\nbeta\r\nalpha again\r\n")
        let hit = t.state.search(for: "alpha")
        #expect(hit?.anchor == SelectionPoint(row: 2, column: 0))
        #expect(hit?.head == SelectionPoint(row: 2, column: 5))
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
}
