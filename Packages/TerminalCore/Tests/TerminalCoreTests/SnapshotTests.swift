import Foundation
import Testing
@testable import TerminalCore

/// Round-trip tests for `TerminalStateSnapshot` (session restoration R0):
/// snapshot → decode → identical grid/scrollback/cursor.
struct SnapshotTests {
    /// Feed a script through a `Terminal` and return its settled state.
    private func state(
        columns: Int = 80, rows: Int = 24, scrollbackLimit: Int = 10_000,
        feeding script: [UInt8]
    ) -> TerminalState {
        var terminal = Terminal(columns: columns, rows: rows)
        terminal.scrollbackLimit = scrollbackLimit
        terminal.feed(script)
        return terminal.state
    }

    /// Assert the two states agree on everything the snapshot captures.
    private func expectEquivalent(
        _ a: TerminalState, _ b: TerminalState,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(a.columns == b.columns, sourceLocation: sourceLocation)
        #expect(a.rows == b.rows, sourceLocation: sourceLocation)
        #expect(a.lines == b.lines, sourceLocation: sourceLocation)
        #expect(a.lineWrapped == b.lineWrapped, sourceLocation: sourceLocation)
        #expect(a.scrollback == b.scrollback, sourceLocation: sourceLocation)
        #expect(a.scrollbackWrapped == b.scrollbackWrapped, sourceLocation: sourceLocation)
        #expect(a.evictedLineCount == b.evictedLineCount, sourceLocation: sourceLocation)
        #expect(a.cursor == b.cursor, sourceLocation: sourceLocation)
        #expect(a.cursorStyle == b.cursorStyle, sourceLocation: sourceLocation)
        #expect(a.linkTable == b.linkTable, sourceLocation: sourceLocation)
        #expect(a.promptMarks == b.promptMarks, sourceLocation: sourceLocation)
    }

    /// Snapshot → encode → decode → restore, exercising the `Codable` path the
    /// app uses (a binary container) on the way through.
    private func roundTrip(_ snapshot: TerminalStateSnapshot) throws -> TerminalState {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        let decoded = try PropertyListDecoder().decode(TerminalStateSnapshot.self, from: data)
        #expect(decoded == snapshot)
        return TerminalState(restoring: decoded)
    }

    @Test func restoresPlainTextAndCursor() throws {
        let original = state(feeding: Array("hello world\r\n  indented\r\n".utf8))
        let restored = try roundTrip(original.makeSnapshot())
        expectEquivalent(original, restored)
        #expect(restored.lineText(0) == "hello world")
        #expect(restored.lineText(1) == "  indented")
    }

    @Test func restoresColorsAndAttributes() throws {
        // Bold red on blue, a truecolor run, then a pending SGR with no text.
        var script = Array("\u{1B}[1;31;44mRED\u{1B}[0m ".utf8)
        script += Array("\u{1B}[38;2;10;20;30mTRUE\u{1B}[0m ".utf8)
        script += Array("\u{1B}[3;4m".utf8) // italic+underline left pending
        let original = state(feeding: script)
        let restored = try roundTrip(original.makeSnapshot())
        expectEquivalent(original, restored)
        // The cell-level color/attr packing survives exactly.
        #expect(restored.lines[0][0] == original.lines[0][0])
    }

    @Test func restoresScrollbackBeyondAScreen() throws {
        var script: [UInt8] = []
        for i in 0..<200 { script += Array("line \(i)\r\n".utf8) }
        let original = state(rows: 24, feeding: script)
        #expect(!original.scrollback.isEmpty)
        let restored = try roundTrip(original.makeSnapshot())
        expectEquivalent(original, restored)
    }

    @Test func restoresWrapFlags() throws {
        // 90 chars into an 80-column screen forces an autowrap.
        let original = state(columns: 80, feeding: Array(String(repeating: "x", count: 90).utf8))
        #expect(original.lineWrapped[0])
        let restored = try roundTrip(original.makeSnapshot())
        expectEquivalent(original, restored)
    }

    @Test func restoresHyperlinksAndPromptMarks() throws {
        var script = Array("\u{1B}]133;A\u{07}".utf8)               // prompt start
        script += Array("\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{07}".utf8)
        script += Array("\r\n\u{1B}]133;D;0\u{07}".utf8)            // command done, exit 0
        let original = state(feeding: script)
        #expect(!original.linkTable.isEmpty)
        #expect(!original.promptMarks.isEmpty)
        let restored = try roundTrip(original.makeSnapshot())
        expectEquivalent(original, restored)
        // The link id stored in the cell still resolves after restore.
        let link = restored.lines[0][0].link
        #expect(link != 0)
        #expect(restored.linkURL(link) == "https://example.com")
    }

    @Test func restoresWideCharacters() throws {
        let original = state(feeding: Array("a日本語b\r\n".utf8))
        let restored = try roundTrip(original.makeSnapshot())
        expectEquivalent(original, restored)
    }

    @Test func restoresCursorStyle() throws {
        let original = state(feeding: Array("\u{1B}[3 q".utf8)) // underline cursor
        #expect(original.cursorStyle == .underline)
        let restored = try roundTrip(original.makeSnapshot())
        #expect(restored.cursorStyle == .underline)
    }

    @Test func workingDirectoryHintSurvives() throws {
        let original = state(feeding: Array("pwd\r\n".utf8))
        let restored = try roundTrip(original.makeSnapshot(workingDirectoryHint: "/tmp/work"))
        // The hint rides the snapshot; restore doesn't change the grid.
        let snapshot = original.makeSnapshot(workingDirectoryHint: "/tmp/work")
        #expect(snapshot.workingDirectoryHint == "/tmp/work")
        expectEquivalent(original, restored)
    }

    @Test func snapshotCarriesVersion() {
        let snapshot = state(feeding: Array("hi".utf8)).makeSnapshot()
        #expect(snapshot.version == TerminalStateSnapshot.currentVersion)
    }

    /// A full 10k-line scrollback must stay within the per-surface memory
    /// budget (<100 MB; ARCHITECTURE.md performance budgets).
    @Test func tenKLineScrollbackStaysWithinBudget() throws {
        var script: [UInt8] = []
        for i in 0..<10_000 { script += Array("scrollback line number \(i)\r\n".utf8) }
        let original = state(columns: 80, rows: 24, scrollbackLimit: 10_000, feeding: script)
        let snapshot = original.makeSnapshot()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(snapshot).count
        // 80 cols × ~10k rows × 16 B ≈ 13 MB of cells; comfortably under budget.
        #expect(bytes < 100 * 1024 * 1024)
        let restored = TerminalState(restoring: snapshot)
        expectEquivalent(original, restored)
    }

    /// A truncated cell blob must degrade to a clean grid, never crash
    /// (corruption tolerance is hardened in R4; the codec must not trap).
    @Test func truncatedBlobDecodesToBlanks() {
        var snapshot = state(feeding: Array("data".utf8)).makeSnapshot()
        snapshot.cells = snapshot.cells.prefix(7) // mid-cell cut
        let restored = TerminalState(restoring: snapshot)
        #expect(restored.rows == snapshot.rows)
        #expect(restored.lines.count == snapshot.rows)
        #expect(restored.lines.allSatisfy { $0.count == snapshot.columns })
    }
}
