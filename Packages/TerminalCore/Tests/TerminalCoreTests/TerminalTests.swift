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
}

struct PrintingTests {
    @Test func plainText() {
        var t = makeTerminal()
        t.feed("hello")
        #expect(t.state.lineText(0) == "hello")
        #expect(t.state.cursor == Cursor(x: 5, y: 0))
    }

    @Test func crlfMovesToNextLine() {
        var t = makeTerminal()
        t.feed("ab\r\ncd")
        #expect(t.screen == ["ab", "cd", "", ""])
        #expect(t.state.cursor == Cursor(x: 2, y: 1))
    }

    @Test func bareLineFeedKeepsColumn() {
        var t = makeTerminal()
        t.feed("ab\ncd")
        #expect(t.screen == ["ab", "  cd", "", ""])
    }

    @Test func deferredWrapAtRightEdge() {
        var t = makeTerminal(columns: 5, rows: 3)
        t.feed("12345")
        // Cursor sits on the last column, wrap pending.
        #expect(t.state.cursor == Cursor(x: 4, y: 0))
        t.feed("6")
        #expect(t.screen == ["12345", "6", ""])
        #expect(t.state.cursor == Cursor(x: 1, y: 1))
    }

    @Test func wrapDisabledClampsAtRightEdge() {
        var t = makeTerminal(columns: 5, rows: 3)
        t.feed("\u{1B}[?7l123456789")
        #expect(t.state.lineText(0) == "12349")
    }

    @Test func scrollsAtBottom() {
        var t = makeTerminal(columns: 5, rows: 3)
        t.feed("a\r\nb\r\nc\r\nd")
        #expect(t.screen == ["b", "c", "d"])
        #expect(t.state.cursor == Cursor(x: 1, y: 2))
    }

    @Test func backspaceAndTab() {
        var t = makeTerminal(columns: 20, rows: 2)
        t.feed("ab\u{08}X")
        #expect(t.state.lineText(0) == "aX")
        t.feed("\tZ")
        #expect(t.state.cursor.x == 9)
        #expect(t.state.lineText(0) == "aX      Z")
    }

    @Test func bellIncrementsCounter() {
        var t = makeTerminal()
        t.feed("\u{07}\u{07}")
        #expect(t.state.bellCount == 2)
    }
}

struct UTF8Tests {
    @Test func multibyteScalars() {
        var t = makeTerminal()
        t.feed("é中€")
        #expect(t.state.lineText(0) == "é中€")
        #expect(t.state.cursor.x == 4) // 中 is double-width
    }

    @Test func multibyteSplitAcrossFeeds() {
        var t = makeTerminal()
        let bytes = Array("é".utf8) // 2 bytes
        t.feed([bytes[0]])
        t.feed([bytes[1]])
        #expect(t.state.lineText(0) == "é")
    }

    @Test func invalidBytesBecomeReplacementCharacter() {
        var t = makeTerminal()
        t.feed([0xFF, UInt8(ascii: "a")])
        #expect(t.state.lineText(0) == "\u{FFFD}a")
    }

    @Test func truncatedSequenceThenASCII() {
        var t = makeTerminal()
        t.feed([0xE4, UInt8(ascii: "x")]) // lead byte expecting 2 continuations
        #expect(t.state.lineText(0) == "\u{FFFD}x")
    }

    @Test func overlongEncodingRejected() {
        var t = makeTerminal()
        t.feed([0xE0, 0x80, 0xA0]) // overlong encoding of U+0020
        #expect(t.state.lineText(0) == "\u{FFFD}")
    }
}

struct CursorMovementTests {
    @Test func cupAndRelativeMoves() {
        var t = makeTerminal(columns: 10, rows: 5)
        t.feed("\u{1B}[3;4H")
        #expect(t.state.cursor == Cursor(x: 3, y: 2))
        t.feed("\u{1B}[2A\u{1B}[3C")
        #expect(t.state.cursor == Cursor(x: 6, y: 0))
        t.feed("\u{1B}[B\u{1B}[2D")
        #expect(t.state.cursor == Cursor(x: 4, y: 1))
    }

    @Test func movesClampAtEdges() {
        var t = makeTerminal(columns: 10, rows: 5)
        t.feed("\u{1B}[99A\u{1B}[99D")
        #expect(t.state.cursor == Cursor(x: 0, y: 0))
        t.feed("\u{1B}[99B\u{1B}[99C")
        #expect(t.state.cursor == Cursor(x: 9, y: 4))
        t.feed("\u{1B}[99;99H")
        #expect(t.state.cursor == Cursor(x: 9, y: 4))
    }

    @Test func columnAndRowAddressing() {
        var t = makeTerminal(columns: 10, rows: 5)
        t.feed("\u{1B}[7G\u{1B}[3d")
        #expect(t.state.cursor == Cursor(x: 6, y: 2))
    }

    @Test func saveRestoreCursor() {
        var t = makeTerminal()
        t.feed("\u{1B}[2;5H\u{1B}7\u{1B}[Hx\u{1B}8")
        #expect(t.state.cursor == Cursor(x: 4, y: 1))
    }

    @Test func reverseIndexScrollsDownAtTop() {
        var t = makeTerminal(columns: 5, rows: 3)
        t.feed("a\u{1B}M")
        #expect(t.state.cursor.y == 0)
        #expect(t.screen == ["", "a", ""])
    }
}

struct EraseAndEditTests {
    @Test func eraseInLineVariants() {
        var t = makeTerminal(columns: 5, rows: 2)
        t.feed("abcde\u{1B}[3G\u{1B}[K")
        #expect(t.state.lineText(0) == "ab")
        t.feed("\u{1B}[2;1Habcde\u{1B}[3G\u{1B}[1K")
        #expect(t.state.lineText(1) == "   de")
    }

    @Test func eraseInDisplayBelow() {
        var t = makeTerminal(columns: 3, rows: 3)
        t.feed("aaa\r\nbbb\r\nccc\u{1B}[2;2H\u{1B}[J")
        #expect(t.screen == ["aaa", "b", ""])
    }

    @Test func eraseAll() {
        var t = makeTerminal(columns: 3, rows: 3)
        t.feed("aaa\r\nbbb\u{1B}[2J")
        #expect(t.screen == ["", "", ""])
        // Cursor does not move on ED 2.
        #expect(t.state.cursor == Cursor(x: 2, y: 1))
    }

    @Test func eraseUsesBrushBackground() {
        var t = makeTerminal(columns: 4, rows: 2)
        t.feed("\u{1B}[44mab\u{1B}[2J")
        #expect(t.state.lines[0][0].background == .palette(4))
        #expect(t.state.lines[0][0].glyph == Cell.blank.glyph)
    }

    @Test func insertAndDeleteCharacters() {
        var t = makeTerminal(columns: 6, rows: 1)
        t.feed("abcdef\u{1B}[2G\u{1B}[2@")
        #expect(t.state.lineText(0) == "a  bcd")
        t.feed("\u{1B}[2P")
        #expect(t.state.lineText(0) == "abcd")
    }

    @Test func eraseCharacters() {
        var t = makeTerminal(columns: 6, rows: 1)
        t.feed("abcdef\u{1B}[3G\u{1B}[2X")
        #expect(t.state.lineText(0) == "ab  ef")
    }

    @Test func insertAndDeleteLines() {
        var t = makeTerminal(columns: 3, rows: 4)
        t.feed("a\r\nb\r\nc\r\nd\u{1B}[2;1H\u{1B}[L")
        #expect(t.screen == ["a", "", "b", "c"])
        t.feed("\u{1B}[2M")
        #expect(t.screen == ["a", "c", "", ""])
    }
}

struct SGRTests {
    @Test func basicColorsAndReset() {
        var t = makeTerminal()
        t.feed("\u{1B}[31;44;1mx\u{1B}[0my")
        let x = t.state.lines[0][0]
        #expect(x.foreground == .palette(1))
        #expect(x.background == .palette(4))
        #expect(x.attributes.contains(.bold))
        let y = t.state.lines[0][1]
        #expect(y.foreground == .default)
        #expect(y.background == .default)
        #expect(y.attributes.isEmpty)
    }

    @Test func brightAndAixColors() {
        var t = makeTerminal()
        t.feed("\u{1B}[91mx\u{1B}[103my")
        #expect(t.state.lines[0][0].foreground == .palette(9))
        #expect(t.state.lines[0][1].background == .palette(11))
    }

    @Test func extended256Color() {
        var t = makeTerminal()
        t.feed("\u{1B}[38;5;196mx")
        #expect(t.state.lines[0][0].foreground == .palette(196))
    }

    @Test func extendedTruecolor() {
        var t = makeTerminal()
        t.feed("\u{1B}[48;2;10;20;30mx")
        #expect(t.state.lines[0][0].background == .rgb(10, 20, 30))
    }

    @Test func colonSeparatedColorParams() {
        var t = makeTerminal()
        t.feed("\u{1B}[38:5:42mx")
        #expect(t.state.lines[0][0].foreground == .palette(42))
    }

    @Test func attributeToggles() {
        var t = makeTerminal()
        t.feed("\u{1B}[1;4;7m\u{1B}[24mx")
        let cell = t.state.lines[0][0]
        #expect(cell.attributes.contains(.bold))
        #expect(cell.attributes.contains(.inverse))
        #expect(!cell.attributes.contains(.underlined))
    }
}

struct ModeAndReportTests {
    @Test func privateModes() {
        var t = makeTerminal()
        t.feed("\u{1B}[?1h\u{1B}[?25l\u{1B}[?2004h")
        #expect(t.state.modes.applicationCursorKeys)
        #expect(!t.state.modes.cursorVisible)
        #expect(t.state.modes.bracketedPaste)
        t.feed("\u{1B}[?1l")
        #expect(!t.state.modes.applicationCursorKeys)
    }

    @Test func cursorPositionReport() {
        var t = makeTerminal()
        t.feed("\u{1B}[2;3H\u{1B}[6n")
        #expect(t.drainResponses() == Array("\u{1B}[2;3R".utf8))
        #expect(t.drainResponses().isEmpty)
    }

    @Test func primaryDeviceAttributes() {
        var t = makeTerminal()
        t.feed("\u{1B}[c")
        #expect(t.drainResponses() == Array("\u{1B}[?62;22c".utf8))
    }

    @Test func titleViaBELAndST() {
        var t = makeTerminal()
        t.feed("\u{1B}]0;hello\u{07}")
        #expect(t.state.title == "hello")
        t.feed("\u{1B}]2;wörld\u{1B}\\")
        #expect(t.state.title == "wörld")
    }

    @Test func fullReset() {
        var t = makeTerminal()
        t.feed("x\u{1B}[31m\u{1B}[?1h\u{1B}c")
        #expect(t.screen == ["", "", "", ""])
        #expect(t.state.cursor == Cursor(x: 0, y: 0))
        #expect(!t.state.modes.applicationCursorKeys)
    }
}

struct RobustnessTests {
    @Test func unknownSequencesAreConsumed() {
        var t = makeTerminal()
        t.feed("a\u{1B}[?12;25$pb\u{1B}]52;c;abc\u{07}c\u{1B}P1$tq\u{1B}\\d")
        #expect(t.state.lineText(0) == "abcd")
    }

    @Test func chunkBoundaryInsideCSI() {
        var t = makeTerminal()
        t.feed("\u{1B}[3")
        t.feed("1mx")
        #expect(t.state.lines[0][0].foreground == .palette(1))
    }

    @Test func resizeClipsAndPads() {
        var t = makeTerminal(columns: 6, rows: 3)
        t.feed("abcdef\r\nghi")
        t.resize(columns: 4, rows: 2)
        #expect(t.state.columns == 4)
        #expect(t.state.rows == 2)
        #expect(t.screen == ["abcd", "ghi"])
        t.resize(columns: 8, rows: 3)
        #expect(t.screen == ["abcd", "ghi", ""])
    }

    @Test func garbageDoesNotTrap() {
        var t = makeTerminal()
        var bytes: [UInt8] = []
        for i in 0..<10_000 {
            bytes.append(UInt8(truncatingIfNeeded: i &* 197 &+ 13))
        }
        t.feed(bytes)
        #expect(t.state.cursor.y < t.state.rows)
    }
}
