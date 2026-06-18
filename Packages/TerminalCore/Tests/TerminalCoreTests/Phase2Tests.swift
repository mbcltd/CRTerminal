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

struct ScrollRegionTests {
    @Test func lineFeedScrollsOnlyRegion() {
        var t = makeTerminal(columns: 3, rows: 5)
        t.feed("a\r\nb\r\nc\r\nd\r\ne")
        t.feed("\u{1B}[2;4r") // region rows 2–4
        t.feed("\u{1B}[4;1H\n") // cursor to bottom margin, LF
        #expect(t.screen == ["a", "c", "d", "", "e"])
    }

    @Test func reverseIndexAtTopMarginScrollsRegionDown() {
        var t = makeTerminal(columns: 3, rows: 4)
        t.feed("a\r\nb\r\nc\r\nd")
        t.feed("\u{1B}[2;3r\u{1B}[2;1H\u{1B}M")
        #expect(t.screen == ["a", "", "b", "d"])
    }

    @Test func insertDeleteLinesRespectRegion() {
        var t = makeTerminal(columns: 3, rows: 4)
        t.feed("a\r\nb\r\nc\r\nd")
        t.feed("\u{1B}[1;3r\u{1B}[1;1H\u{1B}[L")
        // Insert at row 1 within region 1–3: d (outside) untouched.
        #expect(t.screen == ["", "a", "b", "d"])
        t.feed("\u{1B}[M")
        #expect(t.screen == ["a", "b", "", "d"])
    }

    @Test func originModeAddressesRelativeToRegion() {
        var t = makeTerminal(columns: 5, rows: 5)
        t.feed("\u{1B}[2;4r\u{1B}[?6h\u{1B}[1;1Hx")
        #expect(t.state.lineText(1) == "x")
        // Addressing clamps to the region in origin mode.
        t.feed("\u{1B}[99;1Hy")
        #expect(t.state.lineText(3) == "y")
        t.feed("\u{1B}[?6l")
        #expect(t.state.cursor == Cursor(x: 0, y: 0))
    }

    @Test func regionResetOnResize() {
        var t = makeTerminal(columns: 5, rows: 5)
        t.feed("\u{1B}[2;3r")
        t.resize(columns: 5, rows: 6)
        #expect(t.state.marginTop == 0)
        #expect(t.state.marginBottom == 5)
    }
}

struct AlternateScreenTests {
    @Test func enterAndExit1049RestoresContentAndCursor() {
        var t = makeTerminal(columns: 10, rows: 3)
        t.feed("hello\u{1B}[?1049h")
        #expect(t.state.isAlternateScreen)
        #expect(t.screen == ["", "", ""])
        t.feed("alt!")
        #expect(t.state.lineText(0) == "alt!")
        t.feed("\u{1B}[?1049l")
        #expect(!t.state.isAlternateScreen)
        #expect(t.state.lineText(0) == "hello")
        #expect(t.state.cursor == Cursor(x: 5, y: 0))
    }

    @Test func alternateScreenDoesNotFeedScrollback() {
        var t = makeTerminal(columns: 3, rows: 2)
        t.feed("\u{1B}[?1049h")
        t.feed("a\r\nb\r\nc\r\nd")
        #expect(t.state.scrollback.isEmpty)
        t.feed("\u{1B}[?1049l")
    }

    @Test func mode47SwitchesWithoutClearingSemantics() {
        var t = makeTerminal(columns: 5, rows: 2)
        t.feed("hi\u{1B}[?47h\u{1B}[?47l")
        #expect(t.state.lineText(0) == "hi")
    }
}

struct ScrollbackTests {
    @Test func scrolledLinesLandInScrollback() {
        var t = makeTerminal(columns: 3, rows: 2)
        t.feed("a\r\nb\r\nc\r\nd")
        #expect(t.state.scrollback.count == 2)
        #expect(TerminalState.text(of: t.state.scrollback[0]) == "a")
        #expect(t.screen == ["c", "d"])
    }

    @Test func viewportComposesScrollbackAndScreen() {
        var t = makeTerminal(columns: 3, rows: 2)
        t.feed("a\r\nb\r\nc\r\nd")
        let viewport = t.state.viewportLines(scrollOffset: 1)
        #expect(viewport.count == 2)
        #expect(TerminalState.text(of: viewport[0]) == "b")
        #expect(TerminalState.text(of: viewport[1]) == "c")
        // Offset clamps to available scrollback.
        let deep = t.state.viewportLines(scrollOffset: 99)
        #expect(TerminalState.text(of: deep[0]) == "a")
    }

    @Test func eraseDisplay3ClearsScrollbackOnly() {
        var t = makeTerminal(columns: 3, rows: 2)
        t.feed("a\r\nb\r\nc")
        #expect(!t.state.scrollback.isEmpty)
        t.feed("\u{1B}[3J")
        #expect(t.state.scrollback.isEmpty)
        #expect(t.screen == ["b", "c"])
    }

    @Test func scrollbackCapEvictsAndTracksAbsoluteIndex() {
        var t = makeTerminal(columns: 3, rows: 2)
        for i in 0..<12_000 {
            t.feed("\(i % 10)\r\n")
        }
        // Cap is 10k with 1024 slack before each trim.
        #expect(t.state.scrollback.count <= 10_000 + 1024)
        #expect(t.state.evictedLineCount > 0)
        // Absolute indexing stays consistent across eviction.
        #expect(t.state.absoluteScreenTop == t.state.evictedLineCount + t.state.scrollback.count)
        let bottomLine = t.state.absoluteLine(t.state.absoluteScreenTop + 1)
        #expect(bottomLine != nil)
    }
}

struct WideCharacterTests {
    @Test func wideCharOccupiesTwoCells() {
        var t = makeTerminal(columns: 6, rows: 2)
        t.feed("中x")
        #expect(t.state.lines[0][0].attributes.contains(.wide))
        #expect(t.state.lines[0][1].attributes.contains(.wideSpacer))
        #expect(t.state.lines[0][2].glyph == UInt32(UnicodeScalar("x").value))
        #expect(t.state.cursor.x == 3)
        #expect(t.state.lineText(0) == "中x")
    }

    @Test func wideCharWrapsEarlyAtLastColumn() {
        var t = makeTerminal(columns: 5, rows: 2)
        t.feed("abcd中")
        #expect(t.state.lineText(0) == "abcd")
        #expect(t.state.lineText(1) == "中")
    }

    @Test func overwritingHalfOfWidePairClearsBoth() {
        var t = makeTerminal(columns: 6, rows: 1)
        t.feed("中\u{1B}[2Gz") // overwrite the spacer cell
        #expect(t.state.lineText(0) == " z")
        #expect(!t.state.lines[0][0].attributes.contains(.wide))
    }

    @Test func combiningMarksAreDroppedNotAdvanced() {
        var t = makeTerminal(columns: 6, rows: 1)
        t.feed([UInt8(ascii: "e"), 0xCC, 0x81]) // e + U+0301 combining acute
        #expect(t.state.cursor.x == 1)
    }

    @Test func emojiAreWide() {
        var t = makeTerminal(columns: 6, rows: 1)
        t.feed("🚀")
        #expect(t.state.lines[0][0].attributes.contains(.wide))
        #expect(t.state.cursor.x == 2)
    }
}

struct CharsetTests {
    @Test func decGraphicsMapsLineDrawing() {
        var t = makeTerminal()
        t.feed("\u{1B}(0qx\u{1B}(Bq")
        #expect(t.state.lineText(0) == "─│q")
    }

    @Test func shiftOutUsesG1() {
        var t = makeTerminal()
        t.feed("\u{1B})0q\u{0E}q\u{0F}q") // G1=graphics, SO, SI
        #expect(t.state.lineText(0) == "q─q")
    }
}

struct TabStopTests {
    @Test func customTabStops() {
        var t = makeTerminal(columns: 20, rows: 1)
        t.feed("\u{1B}[3G\u{1B}H\u{1B}[1G\tx") // HTS at column 3 (x=2)
        #expect(t.state.cursor.x == 3) // tabbed to the stop, printed one char
        t.feed("\u{1B}[3G\u{1B}[0g\u{1B}[1G\t") // clear that stop, tab again
        #expect(t.state.cursor.x == 8) // falls through to the default stop
    }

    @Test func clearAllTabStops() {
        var t = makeTerminal(columns: 20, rows: 1)
        t.feed("\u{1B}[3g\t")
        #expect(t.state.cursor.x == 19)
    }

    @Test func forwardAndBackTab() {
        var t = makeTerminal(columns: 30, rows: 1)
        t.feed("\u{1B}[2I")
        #expect(t.state.cursor.x == 16)
        t.feed("\u{1B}[Z")
        #expect(t.state.cursor.x == 8)
    }
}

struct MiscVTTests {
    @Test func decalnFillsScreen() {
        var t = makeTerminal(columns: 3, rows: 2)
        t.feed("\u{1B}#8")
        #expect(t.screen == ["EEE", "EEE"])
        #expect(t.state.cursor == Cursor(x: 0, y: 0))
    }

    @Test func insertModeShiftsExistingText() {
        var t = makeTerminal(columns: 6, rows: 1)
        t.feed("abc\u{1B}[1G\u{1B}[4hXY\u{1B}[4l")
        #expect(t.state.lineText(0) == "XYabc")
    }

    @Test func repeatLastCharacter() {
        var t = makeTerminal(columns: 10, rows: 1)
        t.feed("x\u{1B}[3b")
        #expect(t.state.lineText(0) == "xxxx")
    }

    @Test func cursorStyleViaDECSCUSR() {
        var t = makeTerminal()
        t.feed("\u{1B}[5 q")
        #expect(t.state.cursorStyle == .bar)
        t.feed("\u{1B}[2 q")
        #expect(t.state.cursorStyle == .block)
        t.feed("\u{1B}[4 q")
        #expect(t.state.cursorStyle == .underline)
    }

    @Test func mouseModesAndEncoding() {
        var t = makeTerminal()
        t.feed("\u{1B}[?1002h\u{1B}[?1006h")
        #expect(t.state.modes.mouseMode == .buttonEvent)
        #expect(t.state.modes.mouseEncoding == .sgr)
        t.feed("\u{1B}[?1002l")
        #expect(t.state.modes.mouseMode == .off)
    }

    @Test func sgrPixelsEncodingMode() {
        var t = makeTerminal()
        t.feed("\u{1B}[?1016h")
        #expect(t.state.modes.mouseEncoding == .sgrPixels)
        t.feed("\u{1B}[?1016l")
        #expect(t.state.modes.mouseEncoding == .legacy)
    }

    @Test func focusReportingMode() {
        var t = makeTerminal()
        t.feed("\u{1B}[?1004h")
        #expect(t.state.modes.focusReporting)
    }

    @Test func secondaryDeviceAttributes() {
        var t = makeTerminal()
        t.feed("\u{1B}[>c")
        #expect(t.drainResponses() == Array("\u{1B}[>0;0;0c".utf8))
    }

    @Test func windowSizeReport() {
        var t = makeTerminal(columns: 10, rows: 4)
        t.feed("\u{1B}[18t")
        #expect(t.drainResponses() == Array("\u{1B}[8;4;10t".utf8))
    }

    @Test func osc52SetsClipboardPayload() {
        var t = makeTerminal()
        t.feed("\u{1B}]52;c;aGVsbG8=\u{07}")
        #expect(t.drainClipboard() == "aGVsbG8=")
        #expect(t.drainClipboard() == nil)
    }

    @Test func osc52QueryIsIgnored() {
        var t = makeTerminal()
        t.feed("\u{1B}]52;c;?\u{07}")
        #expect(t.drainClipboard() == nil)
    }

    @Test func osc11QueryReportsBackground() {
        var t = makeTerminal()
        t.setColors(foreground: (0x1C, 0x1C, 0x1C), background: (0xF7, 0xF6, 0xF2))
        t.feed("\u{1B}]11;?\u{1B}\\")
        #expect(t.drainResponses()
            == Array("\u{1B}]11;rgb:f7f7/f6f6/f2f2\u{1B}\\".utf8))
    }

    @Test func osc10QueryReportsForeground() {
        var t = makeTerminal()
        t.setColors(foreground: (0x1C, 0x1C, 0x1C), background: (0xF7, 0xF6, 0xF2))
        t.feed("\u{1B}]10;?\u{07}")
        #expect(t.drainResponses()
            == Array("\u{1B}]10;rgb:1c1c/1c1c/1c1c\u{1B}\\".utf8))
    }

    @Test func osc10CascadesToBackgroundQuery() {
        // xterm lets one OSC 10 carry several specs that walk 10→11→…; a
        // "?;?" queries both foreground and background in one go.
        var t = makeTerminal()
        t.setColors(foreground: (0x00, 0x00, 0x00), background: (0xFF, 0xFF, 0xFF))
        t.feed("\u{1B}]10;?;?\u{1B}\\")
        #expect(t.drainResponses() == Array(
            "\u{1B}]10;rgb:0000/0000/0000\u{1B}\\\u{1B}]11;rgb:ffff/ffff/ffff\u{1B}\\".utf8))
    }

    @Test func osc11SetOverridesBackgroundAndQueryReportsIt() {
        // A runtime set now wins (issue #25): no reply, but a later "?" reports
        // the override, not the preset background.
        var t = makeTerminal()
        t.setColors(foreground: (0x1C, 0x1C, 0x1C), background: (0xF7, 0xF6, 0xF2))
        t.feed("\u{1B}]11;rgb:0000/0000/0000\u{1B}\\")
        #expect(t.drainResponses().isEmpty)
        #expect(t.state.colorOverrides.background.map { [$0.red, $0.green, $0.blue] } == [0, 0, 0])
        t.feed("\u{1B}]11;?\u{1B}\\")
        #expect(t.drainResponses()
            == Array("\u{1B}]11;rgb:0000/0000/0000\u{1B}\\".utf8))
    }

    @Test func osc110ResetsForegroundToPreset() {
        var t = makeTerminal()
        t.setColors(foreground: (0x1C, 0x1C, 0x1C), background: (0xF7, 0xF6, 0xF2))
        t.feed("\u{1B}]10;rgb:ffff/0000/0000\u{1B}\\")
        #expect(t.state.colorOverrides.foreground != nil)
        t.feed("\u{1B}]110\u{1B}\\") // bare reset, no params
        #expect(t.state.colorOverrides.foreground == nil)
        t.feed("\u{1B}]10;?\u{1B}\\")
        #expect(t.drainResponses()
            == Array("\u{1B}]10;rgb:1c1c/1c1c/1c1c\u{1B}\\".utf8))
    }

    @Test func osc12SetsAndQueriesCursorColor() {
        var t = makeTerminal()
        t.setColors(foreground: (0x1C, 0x1C, 0x1C), background: (0xF7, 0xF6, 0xF2))
        // Unset cursor reports the foreground.
        t.feed("\u{1B}]12;?\u{1B}\\")
        #expect(t.drainResponses() == Array("\u{1B}]12;rgb:1c1c/1c1c/1c1c\u{1B}\\".utf8))
        t.feed("\u{1B}]12;#00ff00\u{1B}\\")
        #expect(t.state.colorOverrides.cursor.map { [$0.red, $0.green, $0.blue] } == [0, 255, 0])
        t.feed("\u{1B}]12;?\u{1B}\\")
        #expect(t.drainResponses() == Array("\u{1B}]12;rgb:0000/ffff/0000\u{1B}\\".utf8))
        t.feed("\u{1B}]112\u{1B}\\")
        #expect(t.state.colorOverrides.cursor == nil)
    }

    @Test func osc10CascadeSetsFgBgCursor() {
        // One OSC 10 carrying three specs flows 10→fg, 11→bg, 12→cursor.
        var t = makeTerminal()
        t.feed("\u{1B}]10;rgb:1111/2222/3333;#445566;red\u{1B}\\")
        #expect(t.state.colorOverrides.foreground.map { [$0.red, $0.green, $0.blue] } == [0x11, 0x22, 0x33])
        #expect(t.state.colorOverrides.background.map { [$0.red, $0.green, $0.blue] } == [0x44, 0x55, 0x66])
        #expect(t.state.colorOverrides.cursor.map { [$0.red, $0.green, $0.blue] } == [255, 0, 0])
    }

    @Test func osc4SetsPaletteSlotAndQueryReportsIt() {
        var t = makeTerminal()
        t.feed("\u{1B}]4;1;rgb:ffff/0000/0000\u{1B}\\")
        #expect(t.state.colorOverrides.palette[1].map { [$0.red, $0.green, $0.blue] } == [255, 0, 0])
        t.feed("\u{1B}]4;1;?\u{1B}\\")
        #expect(t.drainResponses() == Array("\u{1B}]4;1;rgb:ffff/0000/0000\u{1B}\\".utf8))
    }

    @Test func osc4QueryUnsetSlotReportsBasePalette() {
        // Slot 196 in the xterm cube is (255, 0, 0).
        var t = makeTerminal()
        t.feed("\u{1B}]4;196;?\u{1B}\\")
        #expect(t.drainResponses() == Array("\u{1B}]4;196;rgb:ffff/0000/0000\u{1B}\\".utf8))
    }

    @Test func osc4MultiplePairsInOneSequence() {
        var t = makeTerminal()
        t.feed("\u{1B}]4;1;#ff0000;2;rgb:00/ff/00\u{1B}\\")
        #expect(t.state.colorOverrides.palette[1].map { [$0.red, $0.green, $0.blue] } == [255, 0, 0])
        #expect(t.state.colorOverrides.palette[2].map { [$0.red, $0.green, $0.blue] } == [0, 255, 0])
    }

    @Test func osc104ResetsPaletteSlots() {
        var t = makeTerminal()
        t.feed("\u{1B}]4;1;#ff0000;2;#00ff00\u{1B}\\")
        t.feed("\u{1B}]104;1\u{1B}\\") // reset only slot 1
        #expect(t.state.colorOverrides.palette[1] == nil)
        #expect(t.state.colorOverrides.palette[2] != nil)
        t.feed("\u{1B}]104\u{1B}\\") // reset all
        #expect(t.state.colorOverrides.palette.isEmpty)
    }

    @Test func malformedColorSpecsLeaveStateUnchanged() {
        var t = makeTerminal()
        // Bad index, garbage spec, missing fields — none should mutate or trap.
        t.feed("\u{1B}]4;999;#ff0000\u{1B}\\")      // index out of range
        t.feed("\u{1B}]4;1;not-a-color\u{1B}\\")     // unparseable spec
        t.feed("\u{1B}]4;1;rgb:ff/00\u{1B}\\")       // missing channel
        t.feed("\u{1B}]10;rgb:zz/00/00\u{1B}\\")     // bad hex
        #expect(t.state.colorOverrides.palette.isEmpty)
        #expect(t.state.colorOverrides.foreground == nil)
        #expect(t.drainResponses().isEmpty)
    }
}

struct SelectionTests {
    @Test func textExtractionAcrossLines() {
        var t = makeTerminal(columns: 6, rows: 3)
        t.feed("hello\r\nworld")
        let selection = Selection(
            anchor: SelectionPoint(row: t.state.absoluteScreenTop, column: 3),
            head: SelectionPoint(row: t.state.absoluteScreenTop + 1, column: 2))
        #expect(t.state.text(in: selection) == "lo\nwor")
    }

    @Test func lineGranularityTakesFullRows() {
        var t = makeTerminal(columns: 6, rows: 2)
        t.feed("ab\r\ncd")
        let top = t.state.absoluteScreenTop
        let selection = Selection(
            anchor: SelectionPoint(row: top, column: 5),
            head: SelectionPoint(row: top, column: 0),
            granularity: .line)
        #expect(t.state.text(in: selection) == "ab")
    }

    @Test func wordSelectionExpandsAroundPoint() {
        var t = makeTerminal(columns: 20, rows: 1)
        t.feed("ls -la /tmp/foo.txt")
        let top = t.state.absoluteScreenTop
        let word = t.state.wordSelection(row: top, column: 9)
        #expect(t.state.text(in: word) == "/tmp/foo.txt")
    }

    @Test func selectionAcrossScrollback() {
        var t = makeTerminal(columns: 4, rows: 2)
        t.feed("aa\r\nbb\r\ncc\r\ndd")
        // 'aa' and 'bb' are in scrollback now.
        let selection = Selection(
            anchor: SelectionPoint(row: 0, column: 0),
            head: SelectionPoint(row: 3, column: 1))
        #expect(t.state.text(in: selection) == "aa\nbb\ncc\ndd")
    }

    @Test func wideSpacersSkippedInExtraction() {
        var t = makeTerminal(columns: 8, rows: 1)
        t.feed("中文ab")
        let top = t.state.absoluteScreenTop
        let selection = Selection(
            anchor: SelectionPoint(row: top, column: 0),
            head: SelectionPoint(row: top, column: 5))
        #expect(t.state.text(in: selection) == "中文ab")
    }
}

struct MouseEncoderTests {
    @Test func sgrPressAndRelease() {
        let press = MouseEncoder.encode(.press, button: .left, x: 4, y: 9, encoding: .sgr)
        #expect(press == Array("\u{1B}[<0;5;10M".utf8))
        let release = MouseEncoder.encode(.release, button: .left, x: 4, y: 9, encoding: .sgr)
        #expect(release == Array("\u{1B}[<0;5;10m".utf8))
    }

    @Test func sgrDragAndWheel() {
        let drag = MouseEncoder.encode(.drag, button: .left, x: 0, y: 0, encoding: .sgr)
        #expect(drag == Array("\u{1B}[<32;1;1M".utf8))
        let wheel = MouseEncoder.encode(.press, button: .wheelDown, x: 2, y: 3, encoding: .sgr)
        #expect(wheel == Array("\u{1B}[<65;3;4M".utf8))
    }

    @Test func sgrModifiers() {
        let event = MouseEncoder.encode(
            .press, button: .left, x: 0, y: 0, modifiers: [.control], encoding: .sgr)
        #expect(event == Array("\u{1B}[<16;1;1M".utf8))
    }

    @Test func sgrPixelsPressAndRelease() {
        // Same logical cell, but pixel coords drive the report (1-based).
        let press = MouseEncoder.encode(
            .press, button: .left, x: 4, y: 9, pixelX: 47, pixelY: 182,
            encoding: .sgrPixels)
        #expect(press == Array("\u{1B}[<0;48;183M".utf8))
        let release = MouseEncoder.encode(
            .release, button: .left, x: 4, y: 9, pixelX: 47, pixelY: 182,
            encoding: .sgrPixels)
        #expect(release == Array("\u{1B}[<0;48;183m".utf8))
        // Distinct from the cell-based SGR output for the same x/y.
        let sgr = MouseEncoder.encode(.press, button: .left, x: 4, y: 9, encoding: .sgr)
        #expect(press != sgr)
    }

    @Test func sgrPixelsDragAndModifiers() {
        let drag = MouseEncoder.encode(
            .drag, button: .left, x: 0, y: 0, pixelX: 0, pixelY: 0,
            encoding: .sgrPixels)
        #expect(drag == Array("\u{1B}[<32;1;1M".utf8))
        let mod = MouseEncoder.encode(
            .press, button: .left, x: 0, y: 0, pixelX: 12, pixelY: 34,
            modifiers: [.control], encoding: .sgrPixels)
        #expect(mod == Array("\u{1B}[<16;13;35M".utf8))
    }

    @Test func legacyEncodingAndClamp() {
        let press = MouseEncoder.encode(.press, button: .left, x: 0, y: 0, encoding: .legacy)
        #expect(press == [0x1B, UInt8(ascii: "["), UInt8(ascii: "M"), 32, 33, 33])
        let release = MouseEncoder.encode(.release, button: .left, x: 0, y: 0, encoding: .legacy)
        #expect(release[3] == 32 + 3)
        let far = MouseEncoder.encode(.press, button: .left, x: 999, y: 999, encoding: .legacy)
        #expect(far[4] == 255 && far[5] == 255)
    }
}
