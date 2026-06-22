extension TerminalState {
    /// Scrollback search. ASCII letters match case-insensitively (scalar
    /// folding keeps column mapping exact); matches are found within a
    /// visual row. Pass the previous match's anchor as `from` to step
    /// through results; backward searches start strictly before it,
    /// forward searches strictly after.
    public func search(
        for query: String,
        from: SelectionPoint? = nil,
        backward: Bool = true
    ) -> Selection? {
        let folded = query.unicodeScalars.map { Self.fold($0.value) }
        guard !folded.isEmpty else { return nil }
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
            if let (start, end) = Self.match(
                in: line, query: folded, startAfter: startFloor,
                startBefore: startLimit, last: backward) {
                return Selection(
                    anchor: SelectionPoint(row: row, column: start),
                    head: SelectionPoint(row: row, column: end),
                    granularity: .character)
            }
        }
        return nil
    }

    /// Every match in the buffer, in document order (top→bottom, then
    /// left→right within a row). Powers the find bar's `N / total` counter and
    /// index-based navigation. Case-insensitive over ASCII, like `search`.
    public func allMatches(for query: String) -> [Selection] {
        let folded = query.unicodeScalars.map { Self.fold($0.value) }
        guard !folded.isEmpty else { return [] }
        let top = evictedLineCount
        let bottom = absoluteScreenTop + rows - 1

        var results: [Selection] = []
        for row in top...bottom {
            guard let line = absoluteLine(row) else { continue }
            for (start, end) in Self.allMatches(in: line, query: folded) {
                results.append(Selection(
                    anchor: SelectionPoint(row: row, column: start),
                    head: SelectionPoint(row: row, column: end),
                    granularity: .character))
            }
        }
        return results
    }

    /// ASCII-only case folding keeps the scalar↔column map 1:1.
    private static func fold(_ value: UInt32) -> UInt32 {
        value >= 0x41 && value <= 0x5A ? value + 0x20 : value
    }

    /// Finds a match in one row; returns (startColumn, endColumn) with the
    /// end exclusive (past the match's last cell, wide chars included).
    private static func match(
        in line: [Cell], query: [UInt32],
        startAfter: Int, startBefore: Int, last: Bool
    ) -> (Int, Int)? {
        var scalars: [UInt32] = []
        var columnOf: [Int] = []
        scalars.reserveCapacity(line.count)
        for (x, cell) in line.enumerated() where !cell.attributes.contains(.wideSpacer) {
            scalars.append(fold(cell.glyph))
            columnOf.append(x)
        }
        guard scalars.count >= query.count else { return nil }

        var found: (Int, Int)?
        for i in 0...(scalars.count - query.count) {
            let startColumn = columnOf[i]
            guard startColumn > startAfter, startColumn < startBefore else { continue }
            var k = 0
            while k < query.count, scalars[i + k] == query[k] { k += 1 }
            guard k == query.count else { continue }
            let lastIndex = i + query.count - 1
            let lastCell = line[columnOf[lastIndex]]
            let end = columnOf[lastIndex] + (lastCell.attributes.contains(.wide) ? 2 : 1)
            found = (startColumn, end)
            if !last { return found }
        }
        return found
    }

    /// All non-overlapping matches in one row, left→right, each as
    /// (startColumn, endColumn) with the end exclusive (wide chars included).
    private static func allMatches(
        in line: [Cell], query: [UInt32]
    ) -> [(Int, Int)] {
        var scalars: [UInt32] = []
        var columnOf: [Int] = []
        scalars.reserveCapacity(line.count)
        for (x, cell) in line.enumerated() where !cell.attributes.contains(.wideSpacer) {
            scalars.append(fold(cell.glyph))
            columnOf.append(x)
        }
        guard scalars.count >= query.count else { return [] }

        var out: [(Int, Int)] = []
        var i = 0
        while i <= scalars.count - query.count {
            var k = 0
            while k < query.count, scalars[i + k] == query[k] { k += 1 }
            if k == query.count {
                let lastIndex = i + query.count - 1
                let lastCell = line[columnOf[lastIndex]]
                let end = columnOf[lastIndex] + (lastCell.attributes.contains(.wide) ? 2 : 1)
                out.append((columnOf[i], end))
                i += query.count // non-overlapping
            } else {
                i += 1
            }
        }
        return out
    }
}
