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
        // Flatten the row to one scalar per real cell, remembering each
        // scalar's grid column. Wide-cell spacers are skipped so a match's
        // end column can step past the full glyph.
        var scalars: [UInt32] = []
        var columnOf: [Int] = []
        scalars.reserveCapacity(line.count)
        for (x, cell) in line.enumerated() where !cell.attributes.contains(.wideSpacer) {
            scalars.append(cell.glyph)
            columnOf.append(x)
        }
        guard !scalars.isEmpty else { return [] }

        // Maps a half-open scalar index range [lo, hi) to grid columns,
        // expanding the end past a trailing wide glyph.
        func columns(from lo: Int, to hi: Int) -> (Int, Int) {
            let lastIndex = hi - 1
            let lastCell = line[columnOf[lastIndex]]
            let end = columnOf[lastIndex] + (lastCell.attributes.contains(.wide) ? 2 : 1)
            return (columnOf[lo], end)
        }

        switch pattern.kind {
        case let .literal(query, wholeWord, caseSensitive):
            // Fold the row to the query's case basis so comparison is direct;
            // word-boundary tests use the same (folded) scalars, which is
            // fine since folding never changes a scalar's word-ness.
            let row = caseSensitive ? scalars : scalars.map(fold)
            return literalMatches(
                row: row, query: query, wholeWord: wholeWord, columns: columns)
        case let .regex(regex):
            return regexMatches(scalars: scalars, regex: regex, columns: columns)
        }
    }

    private static func literalMatches(
        row scalars: [UInt32], query: [UInt32], wholeWord: Bool,
        columns: (Int, Int) -> (Int, Int)
    ) -> [(Int, Int)] {
        guard scalars.count >= query.count, !query.isEmpty else { return [] }

        var out: [(Int, Int)] = []
        var i = 0
        while i <= scalars.count - query.count {
            var k = 0
            while k < query.count, scalars[i + k] == query[k] { k += 1 }
            if k == query.count {
                let last = i + query.count - 1
                if !wholeWord || isWordBoundaryLiteral(scalars: scalars, lo: i, hi: last + 1) {
                    out.append(columns(i, last + 1))
                    i += query.count // non-overlapping
                    continue
                }
            }
            i += 1
        }
        return out
    }

    /// True when [lo, hi) sits on word boundaries: no word scalar immediately
    /// before `lo` and none immediately at `hi`.
    private static func isWordBoundaryLiteral(scalars: [UInt32], lo: Int, hi: Int) -> Bool {
        let beforeOK = lo == 0 || !isWordScalar(scalars[lo - 1])
        let afterOK = hi >= scalars.count || !isWordScalar(scalars[hi])
        return beforeOK && afterOK
    }

    private static func regexMatches(
        scalars: [UInt32], regex: NSRegularExpression,
        columns: (Int, Int) -> (Int, Int)
    ) -> [(Int, Int)] {
        // Reconstruct the row as a String, tracking the UTF-16 offset of each
        // scalar so a match's NSRange (UTF-16 based) maps back to the scalar
        // index and thus the grid column.
        var text = ""
        var scalarAtUTF16: [Int: Int] = [:] // utf16 offset → scalar index
        var utf16 = 0
        for (index, value) in scalars.enumerated() {
            guard let scalar = Unicode.Scalar(value) else { continue }
            scalarAtUTF16[utf16] = index
            text.unicodeScalars.append(scalar)
            utf16 += scalar.value > 0xFFFF ? 2 : 1
        }
        let total = utf16
        guard total > 0 else { return [] }

        var out: [(Int, Int)] = []
        regex.enumerateMatches(
            in: text, options: [], range: NSRange(location: 0, length: total)
        ) { result, _, _ in
            guard let result, result.range.length > 0 else { return }
            let r = result.range
            guard let lo = scalarAtUTF16[r.location] else { return }
            // The match end is a UTF-16 offset; find the scalar index whose
            // start is at that offset (one past the last matched scalar).
            let endOffset = r.location + r.length
            let hi = scalarAtUTF16[endOffset] ?? scalars.count
            guard hi > lo else { return }
            out.append(columns(lo, hi))
        }
        return out
    }
}
