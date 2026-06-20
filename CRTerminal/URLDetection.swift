import Foundation
import TerminalCore

/// ⌘-click target resolution: URLs and filesystem paths in row text.
enum URLDetection {
    /// Schemed URL from an OSC 8 target (or any explicit string).
    static func url(from string: String) -> URL? {
        guard let url = URL(string: string), url.scheme != nil else { return nil }
        return url
    }

    /// Finds a URL or local path under `column` in a single row of cells.
    static func detect(in line: [Cell], atColumn column: Int) -> URL? {
        locate(in: line, atColumn: column)?.url
    }

    /// Finds a URL or local path under an absolute cell, joining soft-wrapped
    /// rows into one logical line first so URLs that span physical rows aren't
    /// cropped at the row boundary.
    static func detect(in state: TerminalState, atRow row: Int, column: Int) -> URL? {
        locate(in: state, atRow: row, column: column)?.url
    }

    /// Resolves the URL/path under an absolute cell together with the absolute
    /// start/end cells it occupies (which may straddle soft-wrapped rows).
    /// ⌘-click (`detect`) and the ⌘-hover underline share this.
    static func locate(
        in state: TerminalState, atRow row: Int, column: Int
    ) -> (url: URL, start: SelectionPoint, end: SelectionPoint)? {
        guard let logical = logicalLine(in: state, atRow: row, column: column),
              let hit = locate(in: logical.cells, atColumn: logical.clickIndex)
        else { return nil }
        return (hit.url, logical.origin[hit.columns.lowerBound],
                logical.origin[hit.columns.upperBound - 1])
    }

    /// Absolute span of the contiguous OSC 8 hyperlink run under the clicked
    /// cell, joined across soft-wrapped rows. Nil if the cell carries no link.
    static func osc8Span(
        in state: TerminalState, atRow row: Int, column: Int
    ) -> (start: SelectionPoint, end: SelectionPoint)? {
        guard let logical = logicalLine(in: state, atRow: row, column: column)
        else { return nil }
        let id = logical.cells[logical.clickIndex].link
        guard id != 0 else { return nil }
        var lo = logical.clickIndex
        while lo > 0, logical.cells[lo - 1].link == id { lo -= 1 }
        var hi = logical.clickIndex
        while hi + 1 < logical.cells.count, logical.cells[hi + 1].link == id { hi += 1 }
        return (logical.origin[lo], logical.origin[hi])
    }

    /// A logical line rebuilt by concatenating the clicked physical row with
    /// the soft-wrapped rows around it, plus a per-cell map back to absolute
    /// coordinates and the buffer index of the originally-clicked cell.
    private struct LogicalLine {
        var cells: [Cell]
        var origin: [SelectionPoint]   // parallel to `cells`
        var clickIndex: Int
    }

    /// Guards against runaway joins (a degenerate buffer with stuck wrap bits).
    private static let maxLogicalCells = 1 << 14

    private static func logicalLine(
        in state: TerminalState, atRow row: Int, column: Int
    ) -> LogicalLine? {
        guard let clicked = state.absoluteLine(row), column < clicked.count
        else { return nil }
        // Walk back to the logical start: a row is a continuation iff the row
        // above it carries the soft-wrap flag.
        var start = row
        while state.absoluteWrapped(start - 1) { start -= 1 }
        // Concatenate forward while each row wraps into the next.
        var cells: [Cell] = []
        var origin: [SelectionPoint] = []
        var clickIndex = 0
        var r = start
        while let rowCells = state.absoluteLine(r) {
            for (x, cell) in rowCells.enumerated() {
                if r == row, x == column { clickIndex = cells.count }
                cells.append(cell)
                origin.append(SelectionPoint(row: r, column: x))
            }
            if cells.count >= maxLogicalCells { break }
            if state.absoluteWrapped(r) { r += 1 } else { break }
        }
        return LogicalLine(cells: cells, origin: origin, clickIndex: clickIndex)
    }

    /// Resolves the URL/path under `column` together with the cell-column span
    /// it occupies. `detect` (⌘-click) and the ⌘-hover underline share this.
    static func locate(
        in line: [Cell], atColumn column: Int
    ) -> (url: URL, columns: Range<Int>)? {
        // Build row text plus a scalar→column map (wide spacers collapse).
        var scalars = String.UnicodeScalarView()
        var columnOf: [Int] = []
        for (x, cell) in line.enumerated() where !cell.attributes.contains(.wideSpacer) {
            scalars.append(Unicode.Scalar(cell.glyph) ?? " ")
            columnOf.append(x)
        }
        let text = String(scalars)
        guard let scalarIndex = columnOf.lastIndex(where: { $0 <= column }) else { return nil }

        for token in candidates(in: text) {
            let range = token.range
            let start = text.unicodeScalars.distance(
                from: text.unicodeScalars.startIndex, to: range.lowerBound)
            let end = start + text.unicodeScalars.distance(
                from: range.lowerBound, to: range.upperBound)
            guard scalarIndex >= start, scalarIndex < end else { continue }
            // Map the scalar span back to cells (end-1 is the last scalar).
            return (token.url, columnOf[start]..<(columnOf[end - 1] + 1))
        }
        return nil
    }

    private struct Candidate {
        var range: Range<String.UnicodeScalarIndex>
        var url: URL
    }

    private static let urlPattern = try? NSRegularExpression(
        pattern: #"(?:https?|file|ftp)://[^\s<>"'\)\]]+"#)
    private static let pathPattern = try? NSRegularExpression(
        pattern: #"(?:~|\.{0,2})/[\w.@%+=:,\-/~]+"#)

    private static func candidates(in text: String) -> [Candidate] {
        var out: [Candidate] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in urlPattern?.matches(in: text, range: full) ?? [] {
            guard let range = Range(match.range, in: text) else { continue }
            // Strip trailing punctuation that's usually sentence syntax.
            var candidate = String(text[range])
            while let last = candidate.last, ".,;:!?".contains(last) {
                candidate.removeLast()
            }
            if let url = URL(string: candidate), url.scheme != nil {
                out.append(Candidate(
                    range: range.lowerBound..<range.upperBound, url: url))
            }
        }
        for match in pathPattern?.matches(in: text, range: full) ?? [] {
            guard let range = Range(match.range, in: text) else { continue }
            let raw = String(text[range])
            let expanded = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { continue }
            out.append(Candidate(
                range: range.lowerBound..<range.upperBound,
                url: URL(fileURLWithPath: expanded)))
        }
        return out
    }
}
