import Testing
@testable import TerminalCore

private func makeTerminal(columns: Int = 20, rows: Int = 6) -> Terminal {
    Terminal(columns: columns, rows: rows)
}

private extension Terminal {
    mutating func feed(_ text: String) {
        feed(Array(text.utf8))
    }

    /// Mirrors the shell-integration byte order: prompt (A), end-of-prompt
    /// marker (B), the typed command, the echoed newline, output (C), exit (D).
    mutating func runCommand(prompt: String = "$ ", command: String, exit: Int = 0) {
        feed("\u{1B}]133;A\u{07}\(prompt)\u{1B}]133;B\u{07}\(command)\r\n\u{1B}]133;C\u{07}")
        feed("\u{1B}]133;D;\(exit)\u{07}")
    }
}

struct BlockTests {
    @Test func noMarksYieldsNoBlocks() {
        var t = makeTerminal()
        t.feed("plain output with no shell integration\r\n")
        #expect(t.state.blocks.isEmpty)
    }

    @Test func oneCommandIsOneBlock() {
        var t = makeTerminal()
        t.runCommand(command: "git status", exit: 0)
        let blocks = t.state.blocks
        #expect(blocks.count == 1)
        #expect(blocks[0].command == "git status")
        #expect(blocks[0].exitCode == 0)
        #expect(blocks[0].status == .finished(exitCode: 0))
        #expect(blocks[0].succeeded == true)
    }

    @Test func blocksSpanFromMarkToNextMark() {
        var t = makeTerminal(columns: 20, rows: 8)
        t.feed("\u{1B}]133;A\u{07}$ ls\r\n")  // prompt at row 0
        t.feed("file\r\n")                      // output on row 1
        t.feed("\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}$ ")  // finish, new prompt at row 2
        let blocks = t.state.blocks
        #expect(blocks.count == 2)
        // First block runs from its mark up to the second mark.
        #expect(blocks[0].rowRange == 0..<2)
        // Last block runs to the bottom of the live screen (rows = 8).
        #expect(blocks[1].rowRange == 2..<8)
    }

    @Test func runningCommandHasRunningStatus() {
        var t = makeTerminal()
        // Command issued (A/B/C) but no ;D yet.
        t.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}sleep 5\r\n\u{1B}]133;C\u{07}")
        let block = t.state.blocks.first
        #expect(block?.command == "sleep 5")
        #expect(block?.status == .running)
        #expect(block?.succeeded == nil)
    }

    @Test func idlePromptHasPromptStatus() {
        var t = makeTerminal()
        t.feed("\u{1B}]133;A\u{07}$ ")  // fresh prompt, nothing typed
        let block = t.state.blocks.first
        #expect(block?.command == nil)
        #expect(block?.status == .prompt)
    }

    @Test func failedCommandReportsExitCode() {
        var t = makeTerminal()
        t.runCommand(command: "false", exit: 1)
        let block = t.state.blocks.first
        #expect(block?.status == .finished(exitCode: 1))
        #expect(block?.succeeded == false)
    }

    @Test func carriesDirectory() {
        var t = makeTerminal(columns: 40, rows: 6)
        t.feed("\u{1B}]7;file:///Users/me/dev\u{07}")
        t.runCommand(command: "ls -la")
        #expect(t.state.blocks.first?.directory == "/Users/me/dev")
    }

    @Test func sequencesAreStableAndMonotonic() {
        var t = makeTerminal(columns: 40, rows: 12)
        t.runCommand(command: "one")
        t.runCommand(command: "two")
        t.runCommand(command: "three")
        let blocks = t.state.blocks
        #expect(blocks.map(\.command) == ["one", "two", "three"])
        #expect(blocks.compactMap(\.sequence) == [0, 1, 2])
    }

    @Test func alternateScreenSuppressesBlocks() {
        var t = makeTerminal()
        t.runCommand(command: "vim", exit: 0)
        #expect(!t.state.blocks.isEmpty)
        t.feed("\u{1B}[?1049h")  // enter alternate screen
        #expect(t.state.blocks.isEmpty)
        t.feed("\u{1B}[?1049l")  // leave it again
        #expect(!t.state.blocks.isEmpty)
    }

    @Test func spansSurviveReflow() {
        var t = makeTerminal(columns: 10, rows: 6)
        t.feed("0123456789X\r\n")        // wrapped output above the prompt
        t.feed("\u{1B}]133;A\u{07}$ ")   // prompt mark below the wrapped line
        let before = t.state.blocks
        #expect(before.count == 1)
        #expect(before[0].rowRange.lowerBound == 2)  // two visual rows above
        t.resize(columns: 5, rows: 6)
        // Wrapped line now occupies 3 rows; the block's start tracks the prompt.
        let after = t.state.blocks
        #expect(after.count == 1)
        #expect(after[0].rowRange.lowerBound == 3)
    }

    @Test func outputTextExcludesPromptAndCommand() {
        var t = makeTerminal(columns: 20, rows: 6)
        t.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}echo hi\r\n\u{1B}]133;C\u{07}")
        t.feed("hi\r\nthere\r\n\u{1B}]133;D;0\u{07}")
        t.feed("\u{1B}]133;A\u{07}$ ")  // next prompt bounds the block
        let block = t.state.blocks.first!
        #expect(block.command == "echo hi")
        #expect(t.state.outputText(for: block) == "hi\nthere")
    }

    @Test func idlePromptHasNoOutput() {
        var t = makeTerminal()
        t.feed("\u{1B}]133;A\u{07}$ ")
        let block = t.state.blocks.first!
        #expect(block.outputRange == nil)
        #expect(t.state.outputText(for: block) == "")
    }

    @Test func outputTextSurvivesScrollIntoScrollback() {
        var t = makeTerminal(columns: 20, rows: 4)
        t.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}echo hi\r\n\u{1B}]133;C\u{07}")
        t.feed("hi\r\n\u{1B}]133;D;0\u{07}")
        t.feed("\u{1B}]133;A\u{07}$ ")          // bound block 0 before it scrolls up
        for _ in 0..<10 { t.feed("x\r\n") }     // push block 0 into scrollback
        let block = t.state.blocks.first!
        #expect(block.command == "echo hi")
        #expect(t.state.outputText(for: block) == "hi")  // still addressable in scrollback
    }

    @Test func lookupByRowFindsContainingBlock() {
        var t = makeTerminal(columns: 20, rows: 10)
        t.runCommand(command: "one")
        t.runCommand(command: "two")
        let second = t.state.blocks[1]
        let row = second.rowRange.lowerBound
        #expect(t.state.block(atAbsoluteRow: row)?.command == "two")
        // A row before the first mark belongs to no block.
        #expect(t.state.block(atAbsoluteRow: -1) == nil)
    }

    @Test func spansSurviveScrollbackTrim() {
        var t = makeTerminal(columns: 10, rows: 4)
        t.scrollbackLimit = 5
        t.runCommand(command: "first")
        // Push enough lines to evict the first block's rows into oblivion.
        for i in 0..<20 { t.feed("line\(i)\r\n") }
        // Whatever blocks remain must still have valid, ascending, in-range spans.
        let blocks = t.state.blocks
        let top = t.state.evictedLineCount
        let bottom = t.state.absoluteScreenTop + t.state.rows
        for block in blocks {
            #expect(block.rowRange.lowerBound >= top)
            #expect(block.rowRange.upperBound <= bottom)
            #expect(block.rowRange.lowerBound < block.rowRange.upperBound)
        }
    }
}
