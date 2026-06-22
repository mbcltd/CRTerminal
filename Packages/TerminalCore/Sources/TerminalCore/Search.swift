import Foundation

/// Search behaviour toggled by the find bar's grep-style chips: case
/// sensitivity, whole-word boundaries, and regular-expression matching.
/// The default (all `false`) is the historic ASCII case-insensitive
/// substring search.
public struct SearchOptions: Equatable, Sendable {
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }

    public static let `default` = SearchOptions()
}

/// A query compiled against a set of options once, up front — so a regex is
/// validated and built a single time rather than per scanned row, and the
/// find bar can tell "no results" (`pattern != nil`, empty matches) apart
/// from "bad regex" (`pattern == nil`). Construct via `TerminalState`'s
/// search entry points or `SearchPattern(_:options:)` directly.
public struct SearchPattern {
    fileprivate enum Kind {
        /// Scalars to match literally, pre-folded for the chosen case mode
        /// (folding is identity when case-sensitive). `caseSensitive` tells
        /// the matcher whether to fold the scanned row the same way.
        case literal(scalars: [UInt32], wholeWord: Bool, caseSensitive: Bool)
        case regex(NSRegularExpression)
    }
    fileprivate let kind: Kind

    /// Returns `nil` for an empty query or a regex that fails to compile.
    public init?(_ query: String, options: SearchOptions = .default) {
        if options.regex {
            guard !query.isEmpty else { return nil }
            var regexOptions: NSRegularExpression.Options = []
            if !options.caseSensitive { regexOptions.insert(.caseInsensitive) }
            // Whole-word wraps the user's pattern in boundaries; the group
            // keeps alternation (`a|b`) inside the boundaries.
            let source = options.wholeWord ? "\\b(?:\(query))\\b" : query
            guard let regex = try? NSRegularExpression(pattern: source, options: regexOptions) else {
                return nil
            }
            kind = .regex(regex)
        } else {
            let scalars = query.unicodeScalars.map {
                options.caseSensitive ? $0.value : TerminalState.fold($0.value)
            }
            guard !scalars.isEmpty else { return nil }
            kind = .literal(
                scalars: scalars, wholeWord: options.wholeWord,
                caseSensitive: options.caseSensitive)
        }
    }
}

extension TerminalState {
    /// Scrollback search. With the default options ASCII letters match
    /// case-insensitively (scalar folding keeps column mapping exact);
    /// matches are found within a visual row. Pass the previous match's
    /// anchor as `from` to step through results; backward searches start
    /// strictly before it, forward searches strictly after.
    public func search(
        for query: String,
        options: SearchOptions = .default,
        from: SelectionPoint? = nil,
        backward: Bool = true
    ) -> Selection? {
        guard let pattern = SearchPattern(query, options: options) else { return nil }
        return search(pattern: pattern, from: from, backward: backward)
    }

    /// Steps through results for an already-compiled `pattern` (see
    /// `search(for:options:from:backward:)`).
    public func search(
        pattern: SearchPattern,
        from: SelectionPoint? = nil,
        backward: Bool = true
    ) -> Selection? {
        let top = evictedLineCount
        let bottom = absoluteScreenTop + rows - 1

        let rowsToScan: any Sequence<Int> = backward
            ? stride(from: min(from?.row ?? bottom, bottom), through: top, by: -1)
            : AnySequence((max(from?.row ?? top, top))...bottom)
        for row in rowsToScan {
            guard let line = absoluteLine(row) else { continue }
            var startLimit = Int.max // match must start at column < this
            var startFloor = Int.min // … or at column > this
            if let from, row == from.row {
                if backward {
                    startLimit = from.column
                } else {
                    startFloor = from.column
                }
            }
            let matches = Self.matches(in: line, pattern: pattern)
            // Backward wants the last match before the limit, forward the
            // first after the floor.
            let ordered = backward ? matches.reversed() : Array(matches)
            for (start, end) in ordered where start > startFloor && start < startLimit {
                // `matches` reports the end exclusive; Selection heads are
                // inclusive (the last cell), matching mouse/word selection so
                // the highlight and copied text don't run one cell long.
                return Selection(
                    anchor: SelectionPoint(row: row, column: start),
                    head: SelectionPoint(row: row, column: end - 1),
                    granularity: .character)
            }
        }
        return nil
    }

    /// Every match in the buffer, in document order (top→bottom, then
    /// left→right within a row). Powers the find bar's `N / total` counter and
    /// index-based navigation. Honours `options` like `search`.
    public func allMatches(for query: String, options: SearchOptions = .default) -> [Selection] {
        guard let pattern = SearchPattern(query, options: options) else { return [] }
        return allMatches(pattern: pattern)
    }

    /// Every match for an already-compiled `pattern`, in document order.
    public func allMatches(pattern: SearchPattern) -> [Selection] {
        let top = evictedLineCount
        let bottom = absoluteScreenTop + rows - 1

        var results: [Selection] = []
        for row in top...bottom {
            guard let line = absoluteLine(row) else { continue }
            for (start, end) in Self.matches(in: line, pattern: pattern) {
                results.append(Selection(
                    anchor: SelectionPoint(row: row, column: start),
                    head: SelectionPoint(row: row, column: end - 1),
                    granularity: .character))
            }
        }
        return results
    }

    /// ASCII-only case folding keeps the scalar↔column map 1:1.
    fileprivate static func fold(_ value: UInt32) -> UInt32 {
        value >= 0x41 && value <= 0x5A ? value + 0x20 : value
    }

    /// ASCII word character — alphanumeric or underscore — for whole-word
    /// boundary tests.
    private static func isWordScalar(_ value: UInt32) -> Bool {
        (value >= 0x30 && value <= 0x39) // 0-9
            || (value >= 0x41 && value <= 0x5A) // A-Z
            || (value >= 0x61 && value <= 0x7A) // a-z
            || value == 0x5F // _
    }

    /// All non-overlapping matches in one row, left→right, each as
    /// (startColumn, endColumn) with the end exclusive (wide chars included).
    private static func matches(
        in line: [Cell], pattern: SearchPattern
    ) -> [(Int, Int)] {
        switch pattern.kind {
        case let .literal(query, wholeWord, caseSensitive):
            // The common, hot path (every find-bar keystroke): scan the cells
            // in place so no per-line scalar/column arrays are allocated.
            return literalMatches(
                in: line, query: query, wholeWord: wholeWord,
                caseSensitive: caseSensitive)
        case let .regex(regex):
            return regexMatches(in: line, regex: regex)
        }
    }

    /// The folded glyph of a non-spacer cell, for direct comparison against the
    /// (already folded) query.
    private static func glyph(of cell: Cell, caseSensitive: Bool) -> UInt32 {
        caseSensitive ? cell.glyph : fold(cell.glyph)
    }

    /// The next non-`wideSpacer` column at or after `column`, or `line.count`.
    private static func nextGlyphColumn(in line: [Cell], from column: Int) -> Int {
        var c = column
        while c < line.count, line[c].attributes.contains(.wideSpacer) { c += 1 }
        return c
    }

    /// Allocation-free literal scan over the cells. Wide-cell spacers are
    /// skipped (so the query matches against full glyphs) and a match's end
    /// column steps past a trailing wide glyph, matching the column mapping the
    /// old flatten-then-scan path produced.
    private static func literalMatches(
        in line: [Cell], query: [UInt32], wholeWord: Bool, caseSensitive: Bool
    ) -> [(Int, Int)] {
        guard !query.isEmpty, !line.isEmpty else { return [] }

        var out: [(Int, Int)] = []
        var start = nextGlyphColumn(in: line, from: 0)
        while start < line.count {
            // Try to match the whole query from `start`, skipping spacers.
            var col = start
            var lastGlyph = start
            var k = 0
            while k < query.count, col < line.count {
                if line[col].attributes.contains(.wideSpacer) { col += 1; continue }
                guard glyph(of: line[col], caseSensitive: caseSensitive) == query[k] else { break }
                lastGlyph = col
                k += 1
                col += 1
            }
            if k == query.count {
                let end = lastGlyph + (line[lastGlyph].attributes.contains(.wide) ? 2 : 1)
                if !wholeWord || isWordBoundary(in: line, start: start, end: end) {
                    out.append((start, end))
                    start = nextGlyphColumn(in: line, from: end) // non-overlapping
                    continue
                }
            }
            start = nextGlyphColumn(in: line, from: start + 1)
        }
        return out
    }

    /// True when [start, end) sits on word boundaries: no word glyph in the
    /// non-spacer cell immediately before `start` and none at/after `end`.
    private static func isWordBoundary(in line: [Cell], start: Int, end: Int) -> Bool {
        var before = start - 1
        while before >= 0, line[before].attributes.contains(.wideSpacer) { before -= 1 }
        let beforeOK = before < 0 || !isWordScalar(line[before].glyph)
        let after = nextGlyphColumn(in: line, from: end)
        let afterOK = after >= line.count || !isWordScalar(line[after].glyph)
        return beforeOK && afterOK
    }

    private static func regexMatches(
        in line: [Cell], regex: NSRegularExpression
    ) -> [(Int, Int)] {
        // Reconstruct the row as a String, tracking the UTF-16 offset of each
        // real cell so a match's NSRange (UTF-16 based) maps back to the grid
        // column. Wide-cell spacers are skipped, and the column for the cell
        // after a match expands past a trailing wide glyph.
        var text = ""
        var columnAtUTF16: [Int: Int] = [:] // utf16 offset → grid column
        var lastGlyphColumn = -1
        var utf16 = 0
        for (column, cell) in line.enumerated() where !cell.attributes.contains(.wideSpacer) {
            guard let scalar = Unicode.Scalar(cell.glyph) else { continue }
            columnAtUTF16[utf16] = column
            lastGlyphColumn = column
            text.unicodeScalars.append(scalar)
            utf16 += scalar.value > 0xFFFF ? 2 : 1
        }
        let total = utf16
        guard total > 0 else { return [] }
        // The column one past the final glyph, for matches that reach the end.
        let endColumn = lastGlyphColumn < 0 ? line.count
            : lastGlyphColumn + (line[lastGlyphColumn].attributes.contains(.wide) ? 2 : 1)

        var out: [(Int, Int)] = []
        regex.enumerateMatches(
            in: text, options: [], range: NSRange(location: 0, length: total)
        ) { result, _, _ in
            guard let result, result.range.length > 0 else { return }
            let r = result.range
            guard let lo = columnAtUTF16[r.location] else { return }
            // The match end is a UTF-16 offset; the grid column at that offset
            // is the cell after the match (or the row end past a wide glyph).
            let hi = columnAtUTF16[r.location + r.length] ?? endColumn
            guard hi > lo else { return }
            out.append((lo, hi))
        }
        return out
    }
}
