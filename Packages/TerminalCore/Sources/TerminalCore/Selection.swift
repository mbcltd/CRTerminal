/// A point in the scrollback-stable coordinate space: `row` is an absolute
/// line index (0 = first line ever emitted; survives scrollback trimming via
/// `TerminalState.evictedLineCount`).
public struct SelectionPoint: Comparable, Sendable, Equatable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: SelectionPoint, rhs: SelectionPoint) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

public struct Selection: Sendable, Equatable {
    public enum Granularity: Sendable {
        case character
        case word
        case line
    }

    public var anchor: SelectionPoint
    public var head: SelectionPoint
    public var granularity: Granularity

    public init(anchor: SelectionPoint, head: SelectionPoint, granularity: Granularity = .character) {
        self.anchor = anchor
        self.head = head
        self.granularity = granularity
    }

    public var start: SelectionPoint { min(anchor, head) }
    public var end: SelectionPoint { max(anchor, head) }

    public var isEmpty: Bool {
        granularity == .character && anchor == head
    }

    /// Half-open on columns within a row; line granularity spans full rows.
    public func contains(row: Int, column: Int) -> Bool {
        let start = start
        let end = end
        guard row >= start.row, row <= end.row else { return false }
        if granularity == .line { return true }
        if start.row == end.row {
            return column >= start.column && column <= end.column
        }
        if row == start.row { return column >= start.column }
        if row == end.row { return column <= end.column }
        return true
    }
}

extension TerminalState {
    /// Absolute index of the first on-screen row.
    public var absoluteScreenTop: Int {
        evictedLineCount + scrollback.count
    }

    /// Line lookup across scrollback + screen by absolute index.
    public func absoluteLine(_ index: Int) -> [Cell]? {
        let scrollbackIndex = index - evictedLineCount
        if scrollbackIndex >= 0 && scrollbackIndex < scrollback.count {
            return scrollback[scrollbackIndex]
        }
        let screenIndex = index - absoluteScreenTop
        if screenIndex >= 0 && screenIndex < rows {
            return lines[screenIndex]
        }
        return nil
    }

    /// The viewport: `rows` lines ending `scrollOffset` lines back from live.
    public func viewportLines(scrollOffset: Int) -> [[Cell]] {
        let offset = min(max(0, scrollOffset), scrollback.count)
        guard offset > 0 else { return lines }
        var result: [[Cell]] = []
        result.reserveCapacity(rows)
        let top = absoluteScreenTop - offset
        for i in 0..<rows {
            if var line = absoluteLine(top + i) {
                // Scrollback rows may predate a resize; clip or pad.
                if line.count > columns {
                    line.removeLast(line.count - columns)
                } else if line.count < columns {
                    line.append(contentsOf: Array(repeating: Cell.blank, count: columns - line.count))
                }
                result.append(line)
            } else {
                result.append(Array(repeating: Cell.blank, count: columns))
            }
        }
        return result
    }

    /// Selected text with wide-char spacers skipped and trailing blanks
    /// trimmed per line.
    public func text(in selection: Selection) -> String {
        let start = selection.start
        let end = selection.end
        var linesOut: [String] = []
        for row in start.row...end.row {
            guard let line = absoluteLine(row) else { continue }
            let from = (row == start.row && selection.granularity != .line) ? start.column : 0
            let to = (row == end.row && selection.granularity != .line)
                ? min(end.column, line.count - 1) : line.count - 1
            var scalars = String.UnicodeScalarView()
            guard from <= to else {
                linesOut.append("")
                continue
            }
            for column in from...to where column < line.count {
                let cell = line[column]
                if cell.attributes.contains(.wideSpacer) { continue }
                scalars.append(Unicode.Scalar(cell.glyph) ?? "\u{FFFD}")
            }
            var text = String(scalars)
            while text.hasSuffix(" ") { text.removeLast() }
            linesOut.append(text)
        }
        return linesOut.joined(separator: "\n")
    }

    /// Word range for double-click selection.
    public func wordSelection(row: Int, column: Int) -> Selection {
        guard let line = absoluteLine(row), column < line.count else {
            return Selection(
                anchor: SelectionPoint(row: row, column: column),
                head: SelectionPoint(row: row, column: column),
                granularity: .word)
        }
        func isWordCell(_ cell: Cell) -> Bool {
            guard let scalar = Unicode.Scalar(cell.glyph) else { return false }
            if scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar)) {
                return true
            }
            return "_-./~+@".unicodeScalars.contains(scalar)
        }
        var start = column
        var end = column
        if isWordCell(line[column]) {
            while start > 0 && isWordCell(line[start - 1]) { start -= 1 }
            while end + 1 < line.count && isWordCell(line[end + 1]) { end += 1 }
        }
        return Selection(
            anchor: SelectionPoint(row: row, column: start),
            head: SelectionPoint(row: row, column: end),
            granularity: .word)
    }
}
