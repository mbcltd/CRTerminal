public enum MouseMode: Sendable, Equatable {
    case off
    case x10          // ?9: press only
    case normal       // ?1000: press/release/wheel
    case buttonEvent  // ?1002: + drag
    case anyEvent     // ?1003: + motion
}

public enum MouseEncoding: Sendable, Equatable {
    case legacy
    case sgr // ?1006
}

public enum CursorStyle: Sendable, Equatable {
    case block
    case underline
    case bar
}

public struct TerminalModes: Sendable, Equatable {
    /// DECCKM (?1): arrows send SS3 sequences.
    public var applicationCursorKeys = false
    /// DECOM (?6): row addressing relative to the scroll region.
    public var originMode = false
    /// DECAWM (?7).
    public var autowrap = true
    /// DECTCEM (?25).
    public var cursorVisible = true
    /// IRM (SM/RM 4).
    public var insertMode = false
    /// xterm ?2004.
    public var bracketedPaste = false
    /// xterm ?1004: report focus in/out.
    public var focusReporting = false
    /// xterm ?1007: wheel sends arrows on the alternate screen.
    public var alternateScroll = true
    public var mouseMode = MouseMode.off
    public var mouseEncoding = MouseEncoding.legacy
    /// Kitty keyboard protocol flags (CSI > u stack top).
    public var kittyKeyboardFlags = KittyKeyboardFlags()

    public init() {}
}

/// OSC 133 shell-integration mark: where a prompt started, and how the
/// command launched from it ended.
public struct PromptMark: Sendable, Equatable {
    /// Absolute row (stable across scrollback trimming, remapped by reflow).
    public var row: Int
    /// Exit code reported by OSC 133;D, once the command finishes.
    public var exitCode: Int?

    public init(row: Int, exitCode: Int? = nil) {
        self.row = row
        self.exitCode = exitCode
    }
}

/// OSC 9 / OSC 777;notify desktop notification, drained by the app.
public struct TerminalNotification: Sendable, Equatable {
    public var title: String
    public var body: String
}

/// OSC 9;4 (ConEmu-style) task progress; the app shows it per session.
public struct ProgressReport: Sendable, Equatable {
    public enum State: Int, Sendable {
        case normal = 1
        case error = 2
        case indeterminate = 3
        case paused = 4
    }
    public var state: State
    /// 0...100; meaningless when `state` is `.indeterminate`.
    public var percent: Int
}

public struct Cursor: Sendable, Equatable {
    public var x: Int
    public var y: Int
}

struct Brush: Sendable, Equatable {
    var foreground = PackedColor.default
    var background = PackedColor.default
    var attributes = CellAttributes()

    static let initial = Brush()

    func cell(_ glyph: UInt32) -> Cell {
        Cell(glyph: glyph, foreground: foreground, background: background, attributes: attributes)
    }

    /// Erased cells take the brush background (xterm-style BCE) but no attrs.
    var erased: Cell {
        Cell(glyph: Cell.blank.glyph, background: background)
    }
}

enum Charset: Sendable, Equatable {
    case ascii
    case decGraphics
}

/// The screen model: grid + scrollback + cursor + modes + brush. Mutated only
/// by the parser via `TerminalHandler`; a value copy is a consistent snapshot.
public struct TerminalState: Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int
    /// Active screen, row-major `lines[y][x]`, top row first.
    public private(set) var lines: [[Cell]]
    /// Soft-wrap flags parallel to `lines`: true means this row continues
    /// onto the next (set when autowrap fires; drives resize reflow and
    /// rectangular-correct copy). ARCHITECTURE.md's "wrap bit on Row",
    /// stored out-of-band because rows are plain `[Cell]`.
    public private(set) var lineWrapped: [Bool]
    /// Lines scrolled off the primary screen, oldest first.
    public private(set) var scrollback: [[Cell]] = []
    /// Wrap flags parallel to `scrollback`.
    public private(set) var scrollbackWrapped: [Bool] = []
    /// Number of scrollback lines dropped over the cap — the absolute index
    /// of `scrollback[0]`. Keeps selection coordinates stable.
    public private(set) var evictedLineCount = 0
    public var scrollbackLimit = 10_000

    public private(set) var cursor = Cursor(x: 0, y: 0)
    public private(set) var cursorStyle = CursorStyle.block
    public private(set) var modes = TerminalModes()
    public private(set) var isAlternateScreen = false
    public private(set) var title: String?
    /// Bumped on every visible mutation; renderers compare to skip frames.
    public private(set) var generation: UInt64 = 0
    /// Bumped on BEL; the app layer compares and beeps.
    public private(set) var bellCount: UInt64 = 0
    /// OSC 9;4 task progress; nil when no task is reporting. Cleared on
    /// the next prompt mark so a crashed tool doesn't pin a stale bar.
    public private(set) var progress: ProgressReport?
    /// Bytes the terminal wants written back to the application (DSR, DA…).
    var responses: [UInt8] = []
    /// Raw OSC 52 payload (still base64); the app decodes and sets the
    /// pasteboard.
    var pendingClipboard: String?
    /// Desktop notifications (OSC 9 / 777), drained by the app.
    var pendingNotifications: [TerminalNotification] = []

    /// OSC 8 hyperlink targets; cells reference entries by 1-based id.
    /// Capped: a hostile stream can't grow this without bound.
    public private(set) var linkTable: [String] = []
    private var linkIds: [String: UInt16] = [:]
    private var currentLink: UInt16 = 0
    private static let maxLinks = 4096

    /// OSC 133 prompt marks, oldest first, rows ascending.
    public private(set) var promptMarks: [PromptMark] = []
    private static let maxPromptMarks = 2048

    /// Kitty keyboard protocol: pushed flag states (CSI > u / CSI < u).
    private var kittyFlagsStack: [KittyKeyboardFlags] = []
    private static let maxKittyStack = 32

    var brush = Brush.initial
    var pendingWrap = false
    /// Scroll region (DECSTBM), inclusive.
    public private(set) var marginTop = 0
    public private(set) var marginBottom: Int

    private var tabStops: Set<Int>
    private var g0 = Charset.ascii
    private var g1 = Charset.ascii
    private var shiftedOut = false // SO selects G1
    private var lastPrinted: Unicode.Scalar?

    /// Shared blank row: appended rows CoW-share this storage until written,
    /// which makes scrolling allocation-free for untouched cells.
    private var blankRow: [Cell]

    private struct SavedCursor: Sendable {
        var cursor: Cursor
        var brush: Brush
        var originMode: Bool
        var g0: Charset
        var g1: Charset
        var shiftedOut: Bool
    }
    private var savedCursorPrimary: SavedCursor?
    private var savedCursorAlternate: SavedCursor?
    /// Primary screen content while the alternate screen is active.
    private var savedPrimaryLines: [[Cell]]?
    private var savedPrimaryWrapped: [Bool]?

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        marginBottom = self.rows - 1
        blankRow = Array(repeating: .blank, count: self.columns)
        lines = Array(repeating: blankRow, count: self.rows)
        lineWrapped = Array(repeating: false, count: self.rows)
        tabStops = Self.defaultTabStops(columns: self.columns)
    }

    private static func defaultTabStops(columns: Int) -> Set<Int> {
        Set(stride(from: 8, to: columns, by: 8))
    }

    /// Row text with trailing blanks trimmed and wide spacers skipped.
    public func lineText(_ y: Int) -> String {
        guard y >= 0, y < rows else { return "" }
        return Self.text(of: lines[y])
    }

    static func text(of line: [Cell]) -> String {
        var scalars = String.UnicodeScalarView()
        for cell in line where !cell.attributes.contains(.wideSpacer) {
            scalars.append(Unicode.Scalar(cell.glyph) ?? "\u{FFFD}")
        }
        var text = String(scalars)
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    /// Resize with reflow: the primary screen rewraps soft-wrapped logical
    /// lines to the new width and exchanges rows with scrollback when the
    /// height changes (matching iTerm2/Ghostty). The alternate screen is
    /// clipped/extended — full-screen apps repaint on SIGWINCH anyway.
    public mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(1, newColumns)
        let newRows = max(1, newRows)
        guard newColumns != columns || newRows != rows else { return }

        if isAlternateScreen {
            Self.clipGrid(&lines, to: (newColumns, newRows), cursorY: &cursor.y)
            lineWrapped = Array(repeating: false, count: newRows)
            // The primary screen underneath reflows so it's right on exit.
            if var primary = savedPrimaryLines {
                var wrapped = savedPrimaryWrapped
                    ?? Array(repeating: false, count: primary.count)
                var primaryCursor = savedCursorPrimary?.cursor ?? Cursor(x: 0, y: 0)
                reflow(grid: &primary, wrapped: &wrapped, cursor: &primaryCursor,
                       to: (newColumns, newRows))
                savedPrimaryLines = primary
                savedPrimaryWrapped = wrapped
                savedCursorPrimary?.cursor = primaryCursor
            }
        } else {
            // Locals avoid overlapping exclusive access to self (reflow
            // also touches scrollback).
            var grid = lines
            var wrapped = lineWrapped
            var cur = cursor
            reflow(grid: &grid, wrapped: &wrapped, cursor: &cur,
                   to: (newColumns, newRows))
            lines = grid
            lineWrapped = wrapped
            cursor = cur
        }

        for stop in stride(from: (columns / 8 + 1) * 8, to: newColumns, by: 8) {
            tabStops.insert(stop)
        }
        columns = newColumns
        rows = newRows
        blankRow = Array(repeating: .blank, count: newColumns)
        marginTop = 0
        marginBottom = rows - 1
        cursor.x = min(max(0, cursor.x), columns - 1)
        cursor.y = min(max(0, cursor.y), rows - 1)
        pendingWrap = false
        touch()
    }

    /// Alternate screen: plain clip/extend (the old non-reflow behavior).
    private static func clipGrid(
        _ grid: inout [[Cell]], to size: (columns: Int, rows: Int), cursorY: inout Int
    ) {
        let rows = grid.count
        if size.rows < rows {
            // Keep the bottom of the screen (where the prompt lives).
            let dropped = min(rows - size.rows, max(0, cursorY - (size.rows - 1)))
            grid.removeFirst(dropped)
            grid.removeLast(rows - size.rows - dropped)
            cursorY = max(0, cursorY - dropped)
        } else {
            let columns = grid.first?.count ?? size.columns
            grid.append(contentsOf: Array(
                repeating: Array(repeating: Cell.blank, count: columns),
                count: size.rows - rows))
        }
        for y in 0..<size.rows {
            if size.columns < grid[y].count {
                grid[y].removeLast(grid[y].count - size.columns)
            } else {
                grid[y].append(contentsOf: Array(
                    repeating: Cell.blank, count: size.columns - grid[y].count))
            }
        }
    }

    /// Primary-screen resize. Same width → exchange whole rows with
    /// scrollback; new width → rebuild logical lines from the wrap flags,
    /// rewrap, and redistribute, remapping the cursor and prompt marks.
    private mutating func reflow(
        grid: inout [[Cell]], wrapped: inout [Bool], cursor: inout Cursor,
        to size: (columns: Int, rows: Int)
    ) {
        guard size.columns != columns else {
            adjustRows(grid: &grid, wrapped: &wrapped, cursor: &cursor, to: size.rows)
            return
        }
        let newColumns = size.columns
        let newBlank = [Cell](repeating: .blank, count: newColumns)

        // Trailing blank screen rows below the cursor are padding, not content.
        var lastUsed = grid.count - 1
        while lastUsed > cursor.y, Self.isBlankRow(grid[lastUsed]),
              !wrapped[lastUsed - 1] {
            lastUsed -= 1
        }

        let oldRows = scrollback + grid[0...lastUsed]
        let oldWrapped = scrollbackWrapped + wrapped[0...lastUsed]
        let cursorOldIndex = scrollback.count + cursor.y

        var newRows: [[Cell]] = []
        var newWrapped: [Bool] = []
        newRows.reserveCapacity(oldRows.count)
        var oldToNewRow = [Int](repeating: 0, count: oldRows.count)
        var newCursor = (row: 0, col: 0)

        var lineStart = 0
        while lineStart < oldRows.count {
            // Gather one logical line: rows joined by wrap flags.
            var logical: [Cell] = []
            var rowStarts: [Int] = []
            var lineEnd = lineStart
            while true {
                rowStarts.append(logical.count)
                if oldWrapped[lineEnd], lineEnd + 1 < oldRows.count {
                    logical.append(contentsOf: oldRows[lineEnd])
                    lineEnd += 1
                } else {
                    logical.append(contentsOf: Self.trimmed(oldRows[lineEnd]))
                    break
                }
            }

            // Rewrap into rows of the new width; wide pairs never split.
            let baseNewRow = newRows.count
            var emittedStarts: [Int] = []
            var i = 0
            repeat {
                emittedStarts.append(i)
                var row: [Cell] = []
                row.reserveCapacity(newColumns)
                while i < logical.count, row.count < newColumns {
                    if logical[i].attributes.contains(.wide),
                       row.count == newColumns - 1 {
                        row.append(.blank)
                        break
                    }
                    row.append(logical[i])
                    i += 1
                }
                let last = i >= logical.count
                if row.count < newColumns {
                    row.append(contentsOf: repeatElement(
                        .blank, count: newColumns - row.count))
                }
                newRows.append(row)
                newWrapped.append(!last)
            } while i < logical.count

            func place(offset: Int) -> (row: Int, col: Int) {
                var e = emittedStarts.count - 1
                while e > 0, emittedStarts[e] > offset { e -= 1 }
                return (baseNewRow + e,
                        min(offset - emittedStarts[e], newColumns - 1))
            }
            for (k, start) in rowStarts.enumerated() {
                oldToNewRow[lineStart + k] = place(offset: start).row
            }
            if cursorOldIndex >= lineStart, cursorOldIndex <= lineEnd {
                newCursor = place(
                    offset: rowStarts[cursorOldIndex - lineStart] + cursor.x)
            }
            lineStart = lineEnd + 1
        }

        // Redistribute: bottom-align, but never push the cursor off-screen.
        var screenStart = max(0, newRows.count - size.rows)
        screenStart = min(screenStart, newCursor.row)
        scrollback = Array(newRows[..<screenStart])
        scrollbackWrapped = Array(newWrapped[..<screenStart])
        grid = Array(newRows[screenStart...])
        wrapped = Array(newWrapped[screenStart...])
        while grid.count < size.rows {
            grid.append(newBlank)
            wrapped.append(false)
        }
        cursor = Cursor(x: newCursor.col, y: newCursor.row - screenStart)

        promptMarks = promptMarks.compactMap { mark in
            let old = mark.row - evictedLineCount
            guard old >= 0, old < oldToNewRow.count else { return nil }
            var remapped = mark
            remapped.row = evictedLineCount + oldToNewRow[old]
            return remapped
        }
        trimScrollback()
    }

    /// Height-only change: grow pulls rows back out of scrollback; shrink
    /// drops blank padding below the cursor, then evicts from the top.
    private mutating func adjustRows(
        grid: inout [[Cell]], wrapped: inout [Bool], cursor: inout Cursor, to newRows: Int
    ) {
        if newRows > grid.count {
            let pull = min(newRows - grid.count, scrollback.count)
            if pull > 0 {
                grid.insert(contentsOf: scrollback.suffix(pull), at: 0)
                wrapped.insert(contentsOf: scrollbackWrapped.suffix(pull), at: 0)
                scrollback.removeLast(pull)
                scrollbackWrapped.removeLast(pull)
                cursor.y += pull
            }
            while grid.count < newRows {
                grid.append(blankRow)
                wrapped.append(false)
            }
        } else if newRows < grid.count {
            var excess = grid.count - newRows
            while excess > 0, grid.count - 1 > cursor.y,
                  Self.isBlankRow(grid[grid.count - 1]),
                  !wrapped[grid.count - 2] {
                grid.removeLast()
                wrapped.removeLast()
                excess -= 1
            }
            for _ in 0..<excess {
                pushScrollback(grid.removeFirst(), wrapped: wrapped.removeFirst())
            }
            cursor.y = max(0, cursor.y - excess)
        }
    }

    private static func isBlankRow(_ row: [Cell]) -> Bool {
        row.allSatisfy { $0.glyph == Cell.blank.glyph && $0.background == .default }
    }

    /// Row content with trailing blanks removed (for logical-line joins).
    private static func trimmed(_ row: [Cell]) -> ArraySlice<Cell> {
        var end = row.count
        while end > 0, row[end - 1].glyph == Cell.blank.glyph,
              row[end - 1].background == .default,
              !row[end - 1].attributes.contains(.wideSpacer) {
            end -= 1
        }
        return row[..<end]
    }

    // MARK: Internals

    private mutating func touch() {
        generation &+= 1
    }

    private func blankLines(_ count: Int) -> [[Cell]] {
        Array(repeating: blankRow, count: count)
    }

    /// Scrolls the region up; evicts to scrollback only when the region's
    /// top is the screen top on the primary screen.
    private mutating func scrollUpRegion(_ count: Int) {
        let span = marginBottom - marginTop + 1
        let count = min(max(1, count), span)
        if marginTop == 0 && !isAlternateScreen {
            for i in 0..<count { pushScrollback(lines[i], wrapped: lineWrapped[i]) }
        }
        lines.removeSubrange(marginTop..<(marginTop + count))
        lines.insert(contentsOf: blankLines(count), at: marginBottom - count + 1)
        lineWrapped.removeSubrange(marginTop..<(marginTop + count))
        lineWrapped.insert(
            contentsOf: repeatElement(false, count: count), at: marginBottom - count + 1)
    }

    private mutating func scrollDownRegion(_ count: Int) {
        let span = marginBottom - marginTop + 1
        let count = min(max(1, count), span)
        lines.removeSubrange((marginBottom - count + 1)...marginBottom)
        lines.insert(contentsOf: blankLines(count), at: marginTop)
        lineWrapped.removeSubrange((marginBottom - count + 1)...marginBottom)
        lineWrapped.insert(contentsOf: repeatElement(false, count: count), at: marginTop)
    }

    private mutating func pushScrollback(_ line: [Cell], wrapped: Bool = false) {
        scrollback.append(line)
        scrollbackWrapped.append(wrapped)
        trimScrollback()
    }

    private mutating func trimScrollback() {
        guard scrollback.count > scrollbackLimit + 1024 else { return }
        let drop = scrollback.count - scrollbackLimit
        scrollback.removeFirst(drop)
        scrollbackWrapped.removeFirst(drop)
        evictedLineCount += drop
        if let firstKept = promptMarks.firstIndex(where: { $0.row >= evictedLineCount }) {
            promptMarks.removeFirst(firstKept)
        } else if !promptMarks.isEmpty {
            promptMarks.removeAll()
        }
    }

    private mutating func eraseInLine(_ y: Int, _ range: Range<Int>) {
        let clamped = range.clamped(to: 0..<columns)
        for x in clamped {
            lines[y][x] = brush.erased
        }
        // Erasing through the right edge breaks the soft wrap.
        if clamped.upperBound >= columns {
            lineWrapped[y] = false
        }
    }

    private mutating func moveCursor(x: Int? = nil, y: Int? = nil) {
        if let x { cursor.x = min(max(0, x), columns - 1) }
        if let y {
            if modes.originMode {
                cursor.y = min(max(marginTop, y), marginBottom)
            } else {
                cursor.y = min(max(0, y), rows - 1)
            }
        }
        pendingWrap = false
        touch()
    }

    /// CUP/HVP row addressing respects origin mode.
    private mutating func addressCursor(row: Int, column: Int) {
        let y = modes.originMode ? marginTop + row : row
        moveCursor(x: column, y: y)
    }

    private mutating func index() {
        if cursor.y == marginBottom {
            scrollUpRegion(1)
        } else if cursor.y < rows - 1 {
            cursor.y += 1
        }
        touch()
    }

    private mutating func reverseIndex() {
        if cursor.y == marginTop {
            scrollDownRegion(1)
        } else if cursor.y > 0 {
            cursor.y -= 1
        }
        touch()
    }

    private mutating func respond(_ text: String) {
        responses.append(contentsOf: Array(text.utf8))
        touch()
    }

    private mutating func fullReset() {
        if isAlternateScreen, let primary = savedPrimaryLines {
            lines = primary
        }
        isAlternateScreen = false
        savedPrimaryLines = nil
        savedPrimaryWrapped = nil
        lines = blankLines(rows)
        lineWrapped = Array(repeating: false, count: rows)
        cursor = Cursor(x: 0, y: 0)
        cursorStyle = .block
        brush = .initial
        modes = TerminalModes()
        pendingWrap = false
        savedCursorPrimary = nil
        savedCursorAlternate = nil
        marginTop = 0
        marginBottom = rows - 1
        tabStops = Self.defaultTabStops(columns: columns)
        g0 = .ascii
        g1 = .ascii
        shiftedOut = false
        currentLink = 0
        kittyFlagsStack.removeAll()
        promptMarks.removeAll()
        progress = nil
        touch()
    }

    // MARK: Save/restore & screens

    private mutating func saveCursorState() {
        let saved = SavedCursor(
            cursor: cursor, brush: brush, originMode: modes.originMode,
            g0: g0, g1: g1, shiftedOut: shiftedOut)
        if isAlternateScreen {
            savedCursorAlternate = saved
        } else {
            savedCursorPrimary = saved
        }
    }

    private mutating func restoreCursorState() {
        guard let saved = isAlternateScreen ? savedCursorAlternate : savedCursorPrimary
        else { return }
        brush = saved.brush
        modes.originMode = saved.originMode
        g0 = saved.g0
        g1 = saved.g1
        shiftedOut = saved.shiftedOut
        moveCursor(x: saved.cursor.x, y: saved.cursor.y)
    }

    private mutating func enterAlternateScreen(clear: Bool) {
        guard !isAlternateScreen else { return }
        savedPrimaryLines = lines
        savedPrimaryWrapped = lineWrapped
        lines = clear ? blankLines(rows) : blankLines(rows)
        lineWrapped = Array(repeating: false, count: rows)
        isAlternateScreen = true
        pendingWrap = false
        touch()
    }

    private mutating func exitAlternateScreen() {
        guard isAlternateScreen else { return }
        lines = savedPrimaryLines ?? blankLines(rows)
        lineWrapped = savedPrimaryWrapped ?? Array(repeating: false, count: rows)
        savedPrimaryLines = nil
        savedPrimaryWrapped = nil
        isAlternateScreen = false
        pendingWrap = false
        touch()
    }

    // MARK: Printing

    private var activeCharset: Charset {
        shiftedOut ? g1 : g0
    }

    private mutating func writeCell(_ glyph: Unicode.Scalar, width: Int) {
        clearWidePair(at: cursor.x, row: cursor.y)
        var cell = brush.cell(glyph.value)
        cell.link = currentLink
        lines[cursor.y][cursor.x] = cell
        if width == 2 {
            lines[cursor.y][cursor.x].attributes.insert(.wide)
            if cursor.x + 1 < columns {
                clearWidePair(at: cursor.x + 1, row: cursor.y)
                var spacer = brush.cell(Cell.blank.glyph)
                spacer.attributes.insert(.wideSpacer)
                spacer.link = currentLink
                lines[cursor.y][cursor.x + 1] = spacer
            }
        }
    }

    /// Overwriting half of a wide pair blanks the other half.
    private mutating func clearWidePair(at x: Int, row y: Int) {
        let cell = lines[y][x]
        if cell.attributes.contains(.wideSpacer), x > 0,
           lines[y][x - 1].attributes.contains(.wide) {
            lines[y][x - 1] = brush.erased
        } else if cell.attributes.contains(.wide), x + 1 < columns,
                  lines[y][x + 1].attributes.contains(.wideSpacer) {
            lines[y][x + 1] = brush.erased
        }
    }
}

// MARK: - TerminalHandler

extension TerminalState: TerminalHandler {
    public mutating func printScalar(_ scalar: Unicode.Scalar) {
        let scalar = Self.translate(scalar, charset: activeCharset)
        let width = CharacterWidth.width(of: scalar)
        guard width > 0 else { return } // combining marks: side table in Phase 3
        lastPrinted = scalar
        printResolved(scalar, width: width)
    }

    /// Chunked fast path for printable ASCII runs from the parser. Must match
    /// per-character `printScalar` semantics exactly (deferred wrap, wide-pair
    /// clobbering, REP bookkeeping); falls back when a mode complicates it.
    public mutating func printASCIIRun(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !bytes.isEmpty else { return }
        if activeCharset != .ascii || modes.insertMode {
            for byte in bytes {
                printScalar(Unicode.Scalar(byte))
            }
            return
        }
        lastPrinted = Unicode.Scalar(bytes[bytes.count - 1])
        let brush = brush
        let link = currentLink
        var index = 0
        while index < bytes.count {
            if pendingWrap {
                pendingWrap = false
                if modes.autowrap {
                    lineWrapped[cursor.y] = true
                    cursor.x = 0
                    self.index()
                }
            }
            if !modes.autowrap && cursor.x == columns - 1 {
                // Clamped at the right edge: only the final byte survives.
                clearWidePair(at: cursor.x, row: cursor.y)
                var cell = brush.cell(UInt32(bytes[bytes.count - 1]))
                cell.link = link
                lines[cursor.y][cursor.x] = cell
                pendingWrap = true
                break
            }
            let span = min(columns - cursor.x, bytes.count - index)
            let x = cursor.x
            let y = cursor.y
            // Wide pairs straddling the chunk boundary lose their other half.
            clearWidePair(at: x, row: y)
            clearWidePair(at: x + span - 1, row: y)
            lines[y].withUnsafeMutableBufferPointer { row in
                for k in 0..<span {
                    var cell = brush.cell(UInt32(bytes[index + k]))
                    cell.link = link
                    row[x + k] = cell
                }
            }
            cursor.x += span
            if cursor.x >= columns {
                cursor.x = columns - 1
                pendingWrap = true
            }
            index += span
        }
        touch()
    }

    private mutating func printResolved(_ scalar: Unicode.Scalar, width: Int) {
        if pendingWrap {
            pendingWrap = false
            if modes.autowrap {
                lineWrapped[cursor.y] = true
                cursor.x = 0
                index()
            }
        }
        // A wide char that doesn't fit in the last column wraps early.
        if width == 2 && cursor.x == columns - 1 {
            if modes.autowrap {
                lines[cursor.y][cursor.x] = brush.erased
                lineWrapped[cursor.y] = true
                cursor.x = 0
                index()
            } else if columns >= 2 {
                cursor.x = columns - 2
            }
        }
        if modes.insertMode {
            shiftRightForInsert(width)
        }
        writeCell(scalar, width: width)
        if cursor.x + width >= columns {
            cursor.x = columns - 1
            pendingWrap = true
        } else {
            cursor.x += width
        }
        touch()
    }

    private mutating func shiftRightForInsert(_ count: Int) {
        let count = min(count, columns - cursor.x)
        lines[cursor.y].removeLast(count)
        lines[cursor.y].insert(
            contentsOf: Array(repeating: brush.erased, count: count), at: cursor.x)
    }

    public mutating func executeControl(_ byte: UInt8) {
        switch byte {
        case 0x07: // BEL
            bellCount &+= 1
            touch()
        case 0x08: // BS
            if cursor.x > 0 { cursor.x -= 1 }
            pendingWrap = false
            touch()
        case 0x09: // HT
            cursor.x = nextTabStop(after: cursor.x)
            touch()
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            pendingWrap = false
            index()
        case 0x0D: // CR
            cursor.x = 0
            pendingWrap = false
            touch()
        case 0x0E: // SO: select G1
            shiftedOut = true
        case 0x0F: // SI: select G0
            shiftedOut = false
        default:
            break
        }
    }

    private func nextTabStop(after x: Int) -> Int {
        for stop in (x + 1)..<columns where tabStops.contains(stop) {
            return stop
        }
        return columns - 1
    }

    private func previousTabStop(before x: Int) -> Int {
        for stop in stride(from: x - 1, through: 1, by: -1) where tabStops.contains(stop) {
            return stop
        }
        return 0
    }

    public mutating func escapeDispatch(final: UInt8, intermediates: [UInt8]) {
        if intermediates.count == 1 {
            switch intermediates[0] {
            case UInt8(ascii: "("): // designate G0
                g0 = Self.charset(for: final)
                return
            case UInt8(ascii: ")"): // designate G1
                g1 = Self.charset(for: final)
                return
            case UInt8(ascii: "#") where final == UInt8(ascii: "8"): // DECALN
                let e = Brush.initial.cell(UInt32(UnicodeScalar("E").value))
                lines = Array(
                    repeating: Array(repeating: e, count: columns), count: rows)
                lineWrapped = Array(repeating: false, count: rows)
                marginTop = 0
                marginBottom = rows - 1
                moveCursor(x: 0, y: 0)
                return
            default:
                return
            }
        }
        guard intermediates.isEmpty else { return }
        switch final {
        case UInt8(ascii: "7"): // DECSC
            saveCursorState()
        case UInt8(ascii: "8"): // DECRC
            restoreCursorState()
        case UInt8(ascii: "D"): // IND
            pendingWrap = false
            index()
        case UInt8(ascii: "M"): // RI
            pendingWrap = false
            reverseIndex()
        case UInt8(ascii: "E"): // NEL
            cursor.x = 0
            pendingWrap = false
            index()
        case UInt8(ascii: "H"): // HTS
            tabStops.insert(cursor.x)
        case UInt8(ascii: "c"): // RIS
            fullReset()
        default:
            break
        }
    }

    private static func charset(for final: UInt8) -> Charset {
        final == UInt8(ascii: "0") ? .decGraphics : .ascii
    }

    public mutating func csiDispatch(_ seq: CSISequence) {
        if seq.intermediates == [UInt8(ascii: " ")], seq.final == UInt8(ascii: "q") {
            setCursorStyle(seq.param(0))
            return
        }
        guard seq.intermediates.isEmpty else { return }
        if let prefix = seq.prefix {
            switch prefix {
            case UInt8(ascii: "?"):
                privateDispatch(seq)
            case UInt8(ascii: ">") where seq.final == UInt8(ascii: "c"):
                respond("\u{1B}[>0;0;0c") // secondary DA
            case UInt8(ascii: ">") where seq.final == UInt8(ascii: "u"):
                // Kitty keyboard: push current flags, adopt new ones.
                if kittyFlagsStack.count < Self.maxKittyStack {
                    kittyFlagsStack.append(modes.kittyKeyboardFlags)
                }
                modes.kittyKeyboardFlags = KittyKeyboardFlags(rawValue: seq.param(0))
                touch()
            case UInt8(ascii: "<") where seq.final == UInt8(ascii: "u"):
                // Kitty keyboard: pop; over-popping resets to zero.
                for _ in 0..<max(1, seq.param(0)) {
                    modes.kittyKeyboardFlags = kittyFlagsStack.popLast()
                        ?? KittyKeyboardFlags()
                }
                touch()
            case UInt8(ascii: "=") where seq.final == UInt8(ascii: "u"):
                // Kitty keyboard: set flags in place (mode 1 = assign,
                // 2 = set bits, 3 = clear bits).
                let flags = KittyKeyboardFlags(rawValue: seq.param(0))
                let mode = seq.params.count > 1 ? seq.params[1] : 1
                switch mode {
                case 2: modes.kittyKeyboardFlags.formUnion(flags)
                case 3: modes.kittyKeyboardFlags.subtract(flags)
                default: modes.kittyKeyboardFlags = flags
                }
                touch()
            default:
                break
            }
            return
        }
        switch seq.final {
        case UInt8(ascii: "A"): moveCursor(y: cursor.y - seq.count())
        case UInt8(ascii: "B"): moveCursor(y: cursor.y + seq.count())
        case UInt8(ascii: "C"): moveCursor(x: cursor.x + seq.count())
        case UInt8(ascii: "D"): moveCursor(x: cursor.x - seq.count())
        case UInt8(ascii: "E"): moveCursor(x: 0, y: cursor.y + seq.count())
        case UInt8(ascii: "F"): moveCursor(x: 0, y: cursor.y - seq.count())
        case UInt8(ascii: "G"), UInt8(ascii: "`"): moveCursor(x: seq.count() - 1)
        case UInt8(ascii: "d"): moveCursor(y: seq.count() - 1)
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            addressCursor(row: seq.count(0) - 1, column: seq.count(1) - 1)
        case UInt8(ascii: "I"): // CHT
            for _ in 0..<seq.count() { cursor.x = nextTabStop(after: cursor.x) }
            touch()
        case UInt8(ascii: "Z"): // CBT
            for _ in 0..<seq.count() { cursor.x = previousTabStop(before: cursor.x) }
            touch()
        case UInt8(ascii: "J"): eraseInDisplay(seq.param(0))
        case UInt8(ascii: "K"): eraseInLineDispatch(seq.param(0))
        case UInt8(ascii: "L"): insertLines(seq.count())
        case UInt8(ascii: "M"): deleteLines(seq.count())
        case UInt8(ascii: "@"): insertCharacters(seq.count())
        case UInt8(ascii: "P"): deleteCharacters(seq.count())
        case UInt8(ascii: "X"): eraseCharacters(seq.count())
        case UInt8(ascii: "S"): scrollUpRegion(seq.count()); touch()
        case UInt8(ascii: "T"): scrollDownRegion(seq.count()); touch()
        case UInt8(ascii: "b"): // REP
            if let last = lastPrinted {
                let width = CharacterWidth.width(of: last)
                for _ in 0..<min(seq.count(), columns * rows) {
                    printResolved(last, width: width)
                }
            }
        case UInt8(ascii: "g"): // TBC
            switch seq.param(0) {
            case 0: tabStops.remove(cursor.x)
            case 3: tabStops.removeAll()
            default: break
            }
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            let enable = seq.final == UInt8(ascii: "h")
            for mode in seq.params where mode == 4 {
                modes.insertMode = enable
            }
            touch()
        case UInt8(ascii: "m"): applySGR(seq.params)
        case UInt8(ascii: "n"): deviceStatusReport(seq.param(0), private: false)
        case UInt8(ascii: "c"): respond("\u{1B}[?62;22c") // primary DA: VT220 + color
        case UInt8(ascii: "r"): // DECSTBM
            setScrollRegion(top: seq.param(0), bottom: seq.param(1))
        case UInt8(ascii: "s"): saveCursorState()
        case UInt8(ascii: "u"): restoreCursorState()
        case UInt8(ascii: "t"): // XTWINOPS
            if seq.param(0) == 18 {
                respond("\u{1B}[8;\(rows);\(columns)t")
            }
        default:
            break
        }
    }

    private mutating func setCursorStyle(_ param: Int) {
        switch param {
        case 0, 1, 2: cursorStyle = .block
        case 3, 4: cursorStyle = .underline
        case 5, 6: cursorStyle = .bar
        default: return
        }
        touch()
    }

    private mutating func setScrollRegion(top: Int, bottom: Int) {
        let newTop = max(1, top) - 1
        let newBottom = (bottom == 0 ? rows : min(bottom, rows)) - 1
        guard newTop < newBottom else { return }
        marginTop = newTop
        marginBottom = newBottom
        addressCursor(row: 0, column: 0)
    }

    public mutating func oscDispatch(_ payload: [UInt8]) {
        guard let separator = payload.firstIndex(of: UInt8(ascii: ";")),
              let code = Int(String(decoding: payload[..<separator], as: UTF8.self))
        else { return }
        let body = payload[(separator + 1)...]
        switch code {
        case 0, 2:
            title = String(decoding: body, as: UTF8.self)
            touch()
        case 8:
            // "8;params;uri" — empty uri ends the link span.
            if let uriStart = body.firstIndex(of: UInt8(ascii: ";")) {
                let uri = String(decoding: body[(uriStart + 1)...], as: UTF8.self)
                currentLink = uri.isEmpty ? 0 : linkId(for: uri)
            }
        case 9:
            // "9;4;state;percent" is ConEmu progress, not a notification.
            if body.first == UInt8(ascii: "4"),
               body.count == 1 || body.dropFirst().first == UInt8(ascii: ";") {
                applyProgress(body.dropFirst(2))
            } else {
                pendingNotifications.append(TerminalNotification(
                    title: "", body: String(decoding: body, as: UTF8.self)))
                touch()
            }
        case 52:
            // "52;c;<base64>" — ignore queries ("?"); app decodes payload.
            if let dataStart = body.firstIndex(of: UInt8(ascii: ";")) {
                let data = body[(dataStart + 1)...]
                if data.first != UInt8(ascii: "?") {
                    pendingClipboard = String(decoding: data, as: UTF8.self)
                    touch()
                }
            }
        case 133:
            handleShellIntegration(body)
        case 777:
            // "777;notify;title;body"
            let parts = body.split(
                separator: UInt8(ascii: ";"), maxSplits: 2,
                omittingEmptySubsequences: false)
            if parts.count >= 3, String(decoding: parts[0], as: UTF8.self) == "notify" {
                pendingNotifications.append(TerminalNotification(
                    title: String(decoding: parts[1], as: UTF8.self),
                    body: String(decoding: parts[2], as: UTF8.self)))
                touch()
            }
        default:
            break
        }
    }

    // MARK: Hyperlinks & shell integration

    private mutating func linkId(for uri: String) -> UInt16 {
        if let id = linkIds[uri] { return id }
        guard linkTable.count < Self.maxLinks else { return 0 }
        linkTable.append(uri)
        let id = UInt16(linkTable.count)
        linkIds[uri] = id
        return id
    }

    /// The OSC 8 target for a cell's link id.
    public func linkURL(_ id: UInt16) -> String? {
        guard id >= 1, Int(id) <= linkTable.count else { return nil }
        return linkTable[Int(id) - 1]
    }

    /// OSC "9;4;state;percent": everything after "4" arrives here ("" or
    /// ";state;percent"). State 0 (or absent/garbage) clears; an unknown
    /// state is ignored so future extensions can't flicker the bar.
    private mutating func applyProgress(_ params: ArraySlice<UInt8>) {
        let parts = params.split(
            separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
        let state = parts.first.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let percent = parts.count > 1
            ? Int(String(decoding: parts[1], as: UTF8.self)) : nil
        let next: ProgressReport?
        switch state {
        case 0:
            next = nil
        case 1, 2, 4:
            // Error/paused often arrive without a percent: keep the bar
            // where it was and recolor.
            next = ProgressReport(
                state: ProgressReport.State(rawValue: state)!,
                percent: min(max(percent ?? progress?.percent ?? 0, 0), 100))
        case 3:
            next = ProgressReport(state: .indeterminate, percent: 0)
        default:
            return
        }
        if next != progress {
            progress = next
            touch()
        }
    }

    private mutating func handleShellIntegration(_ body: ArraySlice<UInt8>) {
        guard let kind = body.first, !isAlternateScreen else { return }
        switch kind {
        case UInt8(ascii: "A"): // prompt start
            if progress != nil {
                progress = nil
                touch()
            }
            let row = absoluteScreenTop + cursor.y
            guard promptMarks.last?.row != row else { return }
            promptMarks.append(PromptMark(row: row))
            if promptMarks.count > Self.maxPromptMarks {
                promptMarks.removeFirst()
            }
            touch()
        case UInt8(ascii: "D"): // command finished: "D;exit"
            guard let last = promptMarks.indices.last,
                  promptMarks[last].exitCode == nil else { return }
            let parts = body.split(separator: UInt8(ascii: ";"), maxSplits: 1)
            promptMarks[last].exitCode = parts.count > 1
                ? Int(String(decoding: parts[1], as: UTF8.self)) ?? 0 : 0
            touch()
        default:
            break // B (command start) / C (output start): not yet used
        }
    }

    // MARK: Mode + CSI helpers

    private mutating func privateDispatch(_ seq: CSISequence) {
        let enable: Bool
        switch seq.final {
        case UInt8(ascii: "h"): enable = true
        case UInt8(ascii: "l"): enable = false
        case UInt8(ascii: "n"):
            deviceStatusReport(seq.param(0), private: true)
            return
        case UInt8(ascii: "u"): // kitty keyboard query
            respond("\u{1B}[?\(modes.kittyKeyboardFlags.rawValue)u")
            return
        default:
            return
        }
        for mode in seq.params {
            switch mode {
            case 1: modes.applicationCursorKeys = enable
            case 6:
                modes.originMode = enable
                addressCursor(row: 0, column: 0)
            case 7: modes.autowrap = enable
            case 9: modes.mouseMode = enable ? .x10 : .off
            case 25: modes.cursorVisible = enable
            case 47: enable ? enterAlternateScreen(clear: false) : exitAlternateScreen()
            case 1000: modes.mouseMode = enable ? .normal : .off
            case 1002: modes.mouseMode = enable ? .buttonEvent : .off
            case 1003: modes.mouseMode = enable ? .anyEvent : .off
            case 1004: modes.focusReporting = enable
            case 1006: modes.mouseEncoding = enable ? .sgr : .legacy
            case 1007: modes.alternateScroll = enable
            case 2004: modes.bracketedPaste = enable
            case 1047:
                if enable {
                    enterAlternateScreen(clear: true)
                } else {
                    exitAlternateScreen()
                }
            case 1048:
                if enable { saveCursorState() } else { restoreCursorState() }
            case 1049:
                if enable {
                    saveCursorState()
                    enterAlternateScreen(clear: true)
                    addressCursor(row: 0, column: 0)
                } else {
                    exitAlternateScreen()
                    restoreCursorState()
                }
            default:
                break
            }
        }
        touch()
    }

    private mutating func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(cursor.y, cursor.x..<columns)
            for y in (cursor.y + 1)..<rows { eraseInLine(y, 0..<columns) }
        case 1:
            for y in 0..<cursor.y { eraseInLine(y, 0..<columns) }
            eraseInLine(cursor.y, 0..<(cursor.x + 1))
        case 2:
            for y in 0..<rows { eraseInLine(y, 0..<columns) }
        case 3:
            evictedLineCount += scrollback.count
            scrollback.removeAll()
            scrollbackWrapped.removeAll()
            promptMarks.removeAll { $0.row < evictedLineCount }
        default:
            return
        }
        pendingWrap = false
        touch()
    }

    private mutating func eraseInLineDispatch(_ mode: Int) {
        switch mode {
        case 0: eraseInLine(cursor.y, cursor.x..<columns)
        case 1: eraseInLine(cursor.y, 0..<(cursor.x + 1))
        case 2: eraseInLine(cursor.y, 0..<columns)
        default: return
        }
        pendingWrap = false
        touch()
    }

    /// IL/DL operate within the scroll region, from the cursor row.
    private mutating func insertLines(_ count: Int) {
        guard cursor.y >= marginTop, cursor.y <= marginBottom else { return }
        let count = min(count, marginBottom - cursor.y + 1)
        lines.removeSubrange((marginBottom - count + 1)...marginBottom)
        lines.insert(contentsOf: blankLines(count), at: cursor.y)
        lineWrapped.removeSubrange((marginBottom - count + 1)...marginBottom)
        lineWrapped.insert(contentsOf: repeatElement(false, count: count), at: cursor.y)
        pendingWrap = false
        touch()
    }

    private mutating func deleteLines(_ count: Int) {
        guard cursor.y >= marginTop, cursor.y <= marginBottom else { return }
        let count = min(count, marginBottom - cursor.y + 1)
        lines.removeSubrange(cursor.y..<(cursor.y + count))
        lines.insert(contentsOf: blankLines(count), at: marginBottom - count + 1)
        lineWrapped.removeSubrange(cursor.y..<(cursor.y + count))
        lineWrapped.insert(
            contentsOf: repeatElement(false, count: count), at: marginBottom - count + 1)
        pendingWrap = false
        touch()
    }

    private mutating func insertCharacters(_ count: Int) {
        let count = min(count, columns - cursor.x)
        lines[cursor.y].removeLast(count)
        lines[cursor.y].insert(
            contentsOf: Array(repeating: brush.erased, count: count), at: cursor.x)
        pendingWrap = false
        touch()
    }

    private mutating func deleteCharacters(_ count: Int) {
        let count = min(count, columns - cursor.x)
        lines[cursor.y].removeSubrange(cursor.x..<(cursor.x + count))
        lines[cursor.y].append(contentsOf: Array(repeating: brush.erased, count: count))
        pendingWrap = false
        touch()
    }

    private mutating func eraseCharacters(_ count: Int) {
        eraseInLine(cursor.y, cursor.x..<(cursor.x + count))
        pendingWrap = false
        touch()
    }

    private mutating func deviceStatusReport(_ kind: Int, private isPrivate: Bool) {
        switch kind {
        case 5: respond("\u{1B}[0n")
        case 6:
            let row = modes.originMode ? cursor.y - marginTop + 1 : cursor.y + 1
            if isPrivate {
                respond("\u{1B}[?\(row);\(cursor.x + 1)R")
            } else {
                respond("\u{1B}[\(row);\(cursor.x + 1)R")
            }
        default: break
        }
    }

    private mutating func applySGR(_ params: [Int]) {
        var params = params
        if params.isEmpty { params = [0] }
        var i = 0
        while i < params.count {
            switch params[i] {
            case 0: brush = .initial
            case 1: brush.attributes.insert(.bold)
            case 2: brush.attributes.insert(.faint)
            case 3: brush.attributes.insert(.italic)
            case 4: brush.attributes.insert(.underlined)
            case 5, 6: brush.attributes.insert(.blinking)
            case 7: brush.attributes.insert(.inverse)
            case 8: brush.attributes.insert(.hidden)
            case 9: brush.attributes.insert(.struckThrough)
            case 21: brush.attributes.insert(.underlined)
            case 22: brush.attributes.subtract([.bold, .faint])
            case 23: brush.attributes.remove(.italic)
            case 24: brush.attributes.remove(.underlined)
            case 25: brush.attributes.remove(.blinking)
            case 27: brush.attributes.remove(.inverse)
            case 28: brush.attributes.remove(.hidden)
            case 29: brush.attributes.remove(.struckThrough)
            case 30...37: brush.foreground = .palette(UInt8(params[i] - 30))
            case 38:
                let (color, last) = Self.parseExtendedColor(params, at: i)
                if let color { brush.foreground = color }
                i = last
            case 39: brush.foreground = .default
            case 40...47: brush.background = .palette(UInt8(params[i] - 40))
            case 48:
                let (color, last) = Self.parseExtendedColor(params, at: i)
                if let color { brush.background = color }
                i = last
            case 49: brush.background = .default
            case 90...97: brush.foreground = .palette(UInt8(params[i] - 90 + 8))
            case 100...107: brush.background = .palette(UInt8(params[i] - 100 + 8))
            default: break
            }
            i += 1
        }
        touch()
    }

    /// Parses `38;5;n` / `38;2;r;g;b` starting at the 38/48; returns the
    /// color (if well-formed) and the index of the last parameter consumed.
    private static func parseExtendedColor(
        _ params: [Int], at i: Int
    ) -> (PackedColor?, Int) {
        guard i + 1 < params.count else { return (nil, i) }
        switch params[i + 1] {
        case 5 where i + 2 < params.count:
            return (.palette(UInt8(clamping: params[i + 2])), i + 2)
        case 2 where i + 4 < params.count:
            return (.rgb(
                UInt8(clamping: params[i + 2]),
                UInt8(clamping: params[i + 3]),
                UInt8(clamping: params[i + 4])), i + 4)
        default:
            return (nil, i + 1)
        }
    }

    // MARK: Charsets

    private static func translate(_ scalar: Unicode.Scalar, charset: Charset) -> Unicode.Scalar {
        guard charset == .decGraphics,
              scalar.value >= 0x5F, scalar.value <= 0x7E else { return scalar }
        return decGraphics[Int(scalar.value - 0x5F)]
    }

    /// DEC Special Graphics, 0x5F–0x7E.
    private static let decGraphics: [Unicode.Scalar] = [
        " ", "\u{25C6}", "\u{2592}", "\u{2409}", "\u{240C}", "\u{240D}",
        "\u{240A}", "\u{00B0}", "\u{00B1}", "\u{2424}", "\u{240B}", "\u{2518}",
        "\u{2510}", "\u{250C}", "\u{2514}", "\u{253C}", "\u{23BA}", "\u{23BB}",
        "\u{2500}", "\u{23BC}", "\u{23BD}", "\u{251C}", "\u{2524}", "\u{2534}",
        "\u{252C}", "\u{2502}", "\u{2264}", "\u{2265}", "\u{03C0}", "\u{2260}",
        "\u{00A3}", "\u{00B7}",
    ]
}
