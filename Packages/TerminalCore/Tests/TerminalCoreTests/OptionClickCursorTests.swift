import Testing
@testable import TerminalCore

private func makeTerminal(columns: Int = 20, rows: Int = 4) -> Terminal {
    Terminal(columns: columns, rows: rows)
}

private extension Terminal {
    mutating func feed(_ text: String) {
        feed(Array(text.utf8))
    }
}

struct OptionClickCursorTests {
    @Test func sameRowMovesLeftOnePressPerCharacter() {
        var t = makeTerminal()
        t.feed("echo hello") // cursor at x=10
        #expect(t.state.cursorMovementKeys(toX: 5, toY: 0)
                == Array(repeating: .left, count: 5))
    }

    @Test func sameRowMovesRight() {
        var t = makeTerminal()
        t.feed("echo hello")
        t.feed("\u{1B}[1;3H") // cursor to x=2
        #expect(t.state.cursorMovementKeys(toX: 8, toY: 0)
                == Array(repeating: .right, count: 6))
    }

    @Test func clickOnCursorSendsNothing() {
        var t = makeTerminal()
        t.feed("echo hello")
        #expect(t.state.cursorMovementKeys(toX: 10, toY: 0) == [])
    }

    @Test func clickPastEndOfLineClampsToTextEnd() {
        var t = makeTerminal()
        t.feed("echo hello")
        t.feed("\u{1B}[1;3H") // cursor to x=2
        // Text ends at column 10; a click at column 15 walks 8 characters,
        // not 13.
        #expect(t.state.cursorMovementKeys(toX: 15, toY: 0)
                == Array(repeating: .right, count: 8))
    }

    @Test func wideCharactersCountOnePressPerGlyph() {
        var t = makeTerminal()
        t.feed("日本語") // three wide glyphs across columns 0–5, cursor at x=6
        #expect(t.state.cursorMovementKeys(toX: 0, toY: 0)
                == Array(repeating: .left, count: 3))
        // Clicking the spacer half lands after that glyph.
        #expect(t.state.cursorMovementKeys(toX: 1, toY: 0)
                == Array(repeating: .left, count: 2))
    }

    @Test func wrappedLineCrossesRowsHorizontally() {
        var t = makeTerminal(columns: 10, rows: 4)
        t.feed(String(repeating: "x", count: 25)) // rows 0–1 wrap, cursor (5,2)
        // 7 characters left on row 0 + 10 on row 1 + 5 on row 2.
        #expect(t.state.cursorMovementKeys(toX: 3, toY: 0)
                == Array(repeating: .left, count: 22))
    }

    @Test func clickBelowLogicalLineClampsToItsEnd() {
        var t = makeTerminal(columns: 10, rows: 4)
        t.feed(String(repeating: "x", count: 25)) // cursor (5,2), already at end
        #expect(t.state.cursorMovementKeys(toX: 7, toY: 3) == [])
    }

    @Test func clickAboveLogicalLineClampsToItsStart() {
        var t = makeTerminal(columns: 10, rows: 4)
        t.feed("abc\r\n")
        t.feed(String(repeating: "x", count: 25)) // logical line rows 1–3
        #expect(t.state.cursorMovementKeys(toX: 5, toY: 0)
                == Array(repeating: .left, count: 25))
    }

    @Test func pendingWrapCursorSitsAfterTheLastCell() {
        var t = makeTerminal(columns: 5, rows: 3)
        t.feed("12345") // cursor drawn on x=4 with wrap pending
        #expect(t.state.cursorMovementKeys(toX: 0, toY: 0)
                == Array(repeating: .left, count: 5))
    }

    @Test func alternateScreenMovesVerticallyThenHorizontally() {
        var t = makeTerminal(columns: 10, rows: 6)
        t.feed("\u{1B}[?1049h")
        t.feed("\u{1B}[4;6H") // cursor (x:5, y:3)
        #expect(t.state.cursorMovementKeys(toX: 2, toY: 1)
                == [.up, .up, .left, .left, .left])
        #expect(t.state.cursorMovementKeys(toX: 8, toY: 5)
                == [.down, .down, .right, .right, .right])
    }

    @Test func alternateScreenCountsWideGlyphsOnTargetRow() {
        var t = makeTerminal()
        t.feed("\u{1B}[?1049h")
        t.feed("日本語") // cursor at x=6
        #expect(t.state.cursorMovementKeys(toX: 0, toY: 0)
                == Array(repeating: .left, count: 3))
    }

    @Test func outOfRangeTargetClampsToGrid() {
        var t = makeTerminal()
        t.feed("hi")
        #expect(t.state.cursorMovementKeys(toX: -3, toY: -1)
                == Array(repeating: .left, count: 2))
    }
}
