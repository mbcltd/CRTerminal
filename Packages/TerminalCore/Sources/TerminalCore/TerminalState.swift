public struct TerminalModes: Sendable, Equatable {
    /// DECCKM (?1): arrows send SS3 sequences.
    public var applicationCursorKeys = false
    /// DECAWM (?7).
    public var autowrap = true
    /// DECTCEM (?25).
    public var cursorVisible = true
    /// xterm ?2004.
    public var bracketedPaste = false

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

/// The screen model: a fixed-size grid plus cursor, modes and the current
/// attribute brush. Mutated only by the parser via `TerminalHandler`; a value
/// copy is a consistent snapshot (rows are CoW).
public struct TerminalState: Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int
    /// Row-major cells, `lines[y][x]`, top row first.
    public private(set) var lines: [[Cell]]
    public private(set) var cursor = Cursor(x: 0, y: 0)
    public private(set) var modes = TerminalModes()
    public private(set) var title: String?
    /// Bumped on every visible mutation; renderers compare to skip frames.
    public private(set) var generation: UInt64 = 0
    /// Bumped on BEL; the app layer compares and beeps.
    public private(set) var bellCount: UInt64 = 0
    /// Bytes the terminal wants written back to the application (DSR, DA…).
    var responses: [UInt8] = []

    var brush = Brush.initial
    var pendingWrap = false
    var savedCursor: (cursor: Cursor, brush: Brush)?

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        lines = Array(
            repeating: Array(repeating: .blank, count: self.columns),
            count: self.rows)
    }

    /// Row text with trailing blanks trimmed. Drives golden tests and debug dumps.
    public func lineText(_ y: Int) -> String {
        guard y >= 0, y < rows else { return "" }
        var scalars = String.UnicodeScalarView()
        for cell in lines[y] {
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

        if newRows < rows {
            // Keep the bottom of the screen (where the prompt lives).
            let dropped = min(rows - newRows, max(0, cursor.y - (newRows - 1)))
            lines.removeFirst(dropped)
            lines.removeLast(rows - newRows - dropped)
        } else {
            lines.append(contentsOf: Array(
                repeating: Array(repeating: Cell.blank, count: columns),
                count: newRows - rows))
        }
        for y in 0..<newRows {
            if newColumns < lines[y].count {
                lines[y].removeLast(lines[y].count - newColumns)
            } else {
                lines[y].append(contentsOf: Array(
                    repeating: Cell.blank, count: newColumns - lines[y].count))
            }
        }
        columns = newColumns
        rows = newRows
        cursor.x = min(cursor.x, columns - 1)
        cursor.y = min(cursor.y, rows - 1)
        pendingWrap = false
        savedCursor = nil
        touch()
    }

    // MARK: Internals

    private mutating func touch() {
        generation &+= 1
    }

    private mutating func scrollUp(_ count: Int) {
        let count = min(max(1, count), rows)
        lines.removeFirst(count)
        lines.append(contentsOf: blankLines(count))
    }

    private mutating func scrollDown(_ count: Int) {
        let count = min(max(1, count), rows)
        lines.removeLast(count)
        lines.insert(contentsOf: blankLines(count), at: 0)
    }

    private func blankLines(_ count: Int) -> [[Cell]] {
        Array(repeating: Array(repeating: Cell.blank, count: columns), count: count)
    }

    private mutating func eraseInLine(_ y: Int, _ range: Range<Int>) {
        let clamped = range.clamped(to: 0..<columns)
        for x in clamped {
            lines[y][x] = brush.erased
        }
    }

    private mutating func moveCursor(x: Int? = nil, y: Int? = nil) {
        if let x { cursor.x = min(max(0, x), columns - 1) }
        if let y { cursor.y = min(max(0, y), rows - 1) }
        pendingWrap = false
        touch()
    }

    private mutating func index() {
        if cursor.y >= rows - 1 {
            scrollUp(1)
        } else {
            cursor.y += 1
        }
        touch()
    }

    private mutating func reverseIndex() {
        if cursor.y <= 0 {
            scrollDown(1)
        } else {
            cursor.y -= 1
        }
        touch()
    }

    private mutating func respond(_ text: String) {
        responses.append(contentsOf: Array(text.utf8))
        touch()
    }

    private mutating func fullReset() {
        lines = blankLines(rows)
        cursor = Cursor(x: 0, y: 0)
        brush = .initial
        modes = TerminalModes()
        pendingWrap = false
        savedCursor = nil
        touch()
    }
}

// MARK: - TerminalHandler

extension TerminalState: TerminalHandler {
    public mutating func printScalar(_ scalar: Unicode.Scalar) {
        if pendingWrap {
            pendingWrap = false
            if modes.autowrap {
                cursor.x = 0
                index()
            }
        }
        lines[cursor.y][cursor.x] = brush.cell(scalar.value)
        if cursor.x == columns - 1 {
            pendingWrap = true
        } else {
            cursor.x += 1
        }
        touch()
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
        case 0x09: // HT, fixed stops every 8
            cursor.x = min((cursor.x / 8 + 1) * 8, columns - 1)
            touch()
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            pendingWrap = false
            index()
        case 0x0D: // CR
            cursor.x = 0
            pendingWrap = false
            touch()
        default:
            break
        }
    }

    public mutating func escapeDispatch(final: UInt8, intermediates: [UInt8]) {
        guard intermediates.isEmpty else { return } // charset designation etc.
        switch final {
        case UInt8(ascii: "7"): // DECSC
            savedCursor = (cursor, brush)
        case UInt8(ascii: "8"): // DECRC
            if let saved = savedCursor {
                brush = saved.brush
                moveCursor(x: saved.cursor.x, y: saved.cursor.y)
            }
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
        case UInt8(ascii: "c"): // RIS
            fullReset()
        default:
            break
        }
    }

    public mutating func csiDispatch(_ seq: CSISequence) {
        guard seq.intermediates.isEmpty else { return } // DECSCUSR etc., later
        if let prefix = seq.prefix {
            if prefix == UInt8(ascii: "?") {
                privateModeDispatch(seq)
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
            moveCursor(x: seq.count(1) - 1, y: seq.count(0) - 1)
        case UInt8(ascii: "J"): eraseInDisplay(seq.param(0))
        case UInt8(ascii: "K"): eraseInLineDispatch(seq.param(0))
        case UInt8(ascii: "L"): insertLines(seq.count())
        case UInt8(ascii: "M"): deleteLines(seq.count())
        case UInt8(ascii: "@"): insertCharacters(seq.count())
        case UInt8(ascii: "P"): deleteCharacters(seq.count())
        case UInt8(ascii: "X"): eraseCharacters(seq.count())
        case UInt8(ascii: "S"): scrollUp(seq.count()); touch()
        case UInt8(ascii: "T"): scrollDown(seq.count()); touch()
        case UInt8(ascii: "m"): applySGR(seq.params)
        case UInt8(ascii: "n"): deviceStatusReport(seq.param(0))
        case UInt8(ascii: "c"): respond("\u{1B}[?6c") // primary DA: VT102
        case UInt8(ascii: "s"): savedCursor = (cursor, brush)
        case UInt8(ascii: "u"):
            if let saved = savedCursor {
                brush = saved.brush
                moveCursor(x: saved.cursor.x, y: saved.cursor.y)
            }
        default:
            break // includes 'h'/'l' (ANSI modes) and 'r' (regions, Phase 2)
        }
    }

    public mutating func oscDispatch(_ payload: [UInt8]) {
        guard let separator = payload.firstIndex(of: UInt8(ascii: ";")),
              let code = Int(String(decoding: payload[..<separator], as: UTF8.self))
        else { return }
        switch code {
        case 0, 2:
            title = String(decoding: payload[(separator + 1)...], as: UTF8.self)
            touch()
        default:
            break
        }
    }

    // MARK: CSI helpers

    private mutating func privateModeDispatch(_ seq: CSISequence) {
        let enable: Bool
        switch seq.final {
        case UInt8(ascii: "h"): enable = true
        case UInt8(ascii: "l"): enable = false
        default: return
        }
        for mode in seq.params {
            switch mode {
            case 1: modes.applicationCursorKeys = enable
            case 7: modes.autowrap = enable
            case 25: modes.cursorVisible = enable
            case 2004: modes.bracketedPaste = enable
            default: break
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
        case 2, 3:
            for y in 0..<rows { eraseInLine(y, 0..<columns) }
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

    private mutating func insertLines(_ count: Int) {
        let count = min(count, rows - cursor.y)
        lines.removeLast(count)
        lines.insert(contentsOf: blankLines(count), at: cursor.y)
        pendingWrap = false
        touch()
    }

    private mutating func deleteLines(_ count: Int) {
        let count = min(count, rows - cursor.y)
        lines.removeSubrange(cursor.y..<(cursor.y + count))
        lines.append(contentsOf: blankLines(count))
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

    private mutating func deviceStatusReport(_ kind: Int) {
        switch kind {
        case 5: respond("\u{1B}[0n")
        case 6: respond("\u{1B}[\(cursor.y + 1);\(cursor.x + 1)R")
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
}
