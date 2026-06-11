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

    public init() {}
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
    /// Lines scrolled off the primary screen, oldest first.
    public private(set) var scrollback: [[Cell]] = []
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
    /// Bytes the terminal wants written back to the application (DSR, DA…).
    var responses: [UInt8] = []
    /// Raw OSC 52 payload (still base64); the app decodes and sets the
    /// pasteboard.
    var pendingClipboard: String?

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

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        marginBottom = self.rows - 1
        lines = Array(
            repeating: Array(repeating: .blank, count: self.columns),
            count: self.rows)
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

    /// Non-reflow resize: clip or pad. Reflow arrives in Phase 5.
    public mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(1, newColumns)
        let newRows = max(1, newRows)
        guard newColumns != columns || newRows != rows else { return }

        Self.resizeGrid(&lines, rows: rows, to: (newColumns, newRows), cursorY: &cursor.y)
        if savedPrimaryLines != nil {
            var unusedCursorY = 0
            Self.resizeGrid(
                &savedPrimaryLines!, rows: rows, to: (newColumns, newRows),
                cursorY: &unusedCursorY)
        }
        for stop in stride(from: (columns / 8 + 1) * 8, to: newColumns, by: 8) {
            tabStops.insert(stop)
        }
        columns = newColumns
        rows = newRows
        marginTop = 0
        marginBottom = rows - 1
        cursor.x = min(cursor.x, columns - 1)
        cursor.y = min(cursor.y, rows - 1)
        pendingWrap = false
        touch()
    }

    private static func resizeGrid(
        _ grid: inout [[Cell]], rows: Int, to size: (columns: Int, rows: Int),
        cursorY: inout Int
    ) {
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

    // MARK: Internals

    private mutating func touch() {
        generation &+= 1
    }

    private func blankLines(_ count: Int) -> [[Cell]] {
        Array(repeating: Array(repeating: Cell.blank, count: columns), count: count)
    }

    /// Scrolls the region up; evicts to scrollback only when the region's
    /// top is the screen top on the primary screen.
    private mutating func scrollUpRegion(_ count: Int) {
        let span = marginBottom - marginTop + 1
        let count = min(max(1, count), span)
        if marginTop == 0 && !isAlternateScreen {
            for i in 0..<count { pushScrollback(lines[i]) }
        }
        lines.removeSubrange(marginTop..<(marginTop + count))
        lines.insert(contentsOf: blankLines(count), at: marginBottom - count + 1)
    }

    private mutating func scrollDownRegion(_ count: Int) {
        let span = marginBottom - marginTop + 1
        let count = min(max(1, count), span)
        lines.removeSubrange((marginBottom - count + 1)...marginBottom)
        lines.insert(contentsOf: blankLines(count), at: marginTop)
    }

    private mutating func pushScrollback(_ line: [Cell]) {
        scrollback.append(line)
        if scrollback.count > scrollbackLimit + 1024 {
            let drop = scrollback.count - scrollbackLimit
            scrollback.removeFirst(drop)
            evictedLineCount += drop
        }
    }

    private mutating func eraseInLine(_ y: Int, _ range: Range<Int>) {
        let clamped = range.clamped(to: 0..<columns)
        for x in clamped {
            lines[y][x] = brush.erased
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
        lines = blankLines(rows)
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
        lines = clear ? blankLines(rows) : blankLines(rows)
        isAlternateScreen = true
        pendingWrap = false
        touch()
    }

    private mutating func exitAlternateScreen() {
        guard isAlternateScreen else { return }
        lines = savedPrimaryLines ?? blankLines(rows)
        savedPrimaryLines = nil
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
        lines[cursor.y][cursor.x] = brush.cell(glyph.value)
        if width == 2 {
            lines[cursor.y][cursor.x].attributes.insert(.wide)
            if cursor.x + 1 < columns {
                clearWidePair(at: cursor.x + 1, row: cursor.y)
                var spacer = brush.cell(Cell.blank.glyph)
                spacer.attributes.insert(.wideSpacer)
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

    private mutating func printResolved(_ scalar: Unicode.Scalar, width: Int) {
        if pendingWrap {
            pendingWrap = false
            if modes.autowrap {
                cursor.x = 0
                index()
            }
        }
        // A wide char that doesn't fit in the last column wraps early.
        if width == 2 && cursor.x == columns - 1 {
            if modes.autowrap {
                lines[cursor.y][cursor.x] = brush.erased
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
        case 52:
            // "52;c;<base64>" — ignore queries ("?"); app decodes payload.
            if let dataStart = body.firstIndex(of: UInt8(ascii: ";")) {
                let data = body[(dataStart + 1)...]
                if data.first != UInt8(ascii: "?") {
                    pendingClipboard = String(decoding: data, as: UTF8.self)
                    touch()
                }
            }
        default:
            break
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
        pendingWrap = false
        touch()
    }

    private mutating func deleteLines(_ count: Int) {
        guard cursor.y >= marginTop, cursor.y <= marginBottom else { return }
        let count = min(count, marginBottom - cursor.y + 1)
        lines.removeSubrange(cursor.y..<(cursor.y + count))
        lines.insert(contentsOf: blankLines(count), at: marginBottom - count + 1)
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
