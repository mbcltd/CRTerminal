/// Option-click cursor movement (the Terminal.app / iTerm2 gesture): the
/// terminal can't move the application's cursor itself, so a click is
/// translated into the arrow-key presses that walk the cursor to the clicked
/// cell, and the application (readline, zle, vi, any TUI editor) applies them
/// to its own buffer.
extension TerminalState {
    /// Arrow keys that move the application's cursor from where it is now to
    /// the clicked cell, or `[]` when there is nothing to send.
    ///
    /// Arrows move one *character* per press while the grid is indexed by
    /// column, so distances count cells that aren't wide-character spacers.
    /// On the primary screen movement is horizontal-only (up/down at a shell
    /// prompt recall history) and confined to the soft-wrapped logical line
    /// under the cursor, which readline/zle walk with plain left/right; clicks
    /// outside that line clamp to its ends. On the alternate screen (vi and
    /// friends) vertical arrows are safe, so the path is up/down then
    /// left/right along the target row; the application's own end-of-line
    /// clamping makes that path approximate by nature.
    public func cursorMovementKeys(toX targetX: Int, toY targetY: Int) -> [TerminalKey] {
        guard columns > 0, rows > 0 else { return [] }
        let tx = min(max(0, targetX), columns - 1)
        let ty = min(max(0, targetY), rows - 1)
        return isAlternateScreen
            ? alternateScreenKeys(toX: tx, toY: ty)
            : primaryScreenKeys(toX: tx, toY: ty)
    }

    private func primaryScreenKeys(toX targetX: Int, toY targetY: Int) -> [TerminalKey] {
        var first = cursor.y
        while first > 0, lineWrapped[first - 1] { first -= 1 }
        var last = cursor.y
        while last < rows - 1, lineWrapped[last] { last += 1 }
        var (tx, ty) = (targetX, targetY)
        if ty < first { (tx, ty) = (0, first) }
        if ty > last { (tx, ty) = (columns, last) }
        // Clicking past the text means "end of line" — don't walk arrows
        // through the blank region just to bounce them off the buffer end.
        tx = min(tx, textEnd(on: ty))
        // Character offset of a position from the start of the logical line.
        func offset(_ x: Int, _ y: Int) -> Int {
            var count = characters(on: y, in: 0..<x)
            for row in first..<y { count += characters(on: row, in: 0..<columns) }
            return count
        }
        let dx = offset(tx, ty) - offset(cursorColumn, cursor.y)
        return Array(repeating: dx > 0 ? TerminalKey.right : .left, count: abs(dx))
    }

    private func alternateScreenKeys(toX targetX: Int, toY targetY: Int) -> [TerminalKey] {
        let dy = targetY - cursor.y
        let dx = targetX >= cursorColumn
            ? characters(on: targetY, in: cursorColumn..<targetX)
            : -characters(on: targetY, in: targetX..<cursorColumn)
        var keys = Array(repeating: dy > 0 ? TerminalKey.down : .up, count: abs(dy))
        keys += Array(repeating: dx > 0 ? TerminalKey.right : .left, count: abs(dx))
        return keys
    }

    /// The cursor's logical column: with a wrap pending the cursor is drawn
    /// on the last cell but sits after the character in it.
    private var cursorColumn: Int { cursor.x + (pendingWrap ? 1 : 0) }

    /// Cells in `row`'s columns `range` that hold a character (not the spacer
    /// half of a wide glyph) — the arrow presses needed to cross them.
    private func characters(on row: Int, in range: Range<Int>) -> Int {
        guard row >= 0, row < lines.count else { return 0 }
        let line = lines[row]
        let clamped = range.clamped(to: 0..<line.count)
        var count = 0
        for index in clamped where !line[index].attributes.contains(.wideSpacer) {
            count += 1
        }
        return count
    }

    /// One past the last non-blank cell on `row`: where "end of line" is.
    private func textEnd(on row: Int) -> Int {
        guard row >= 0, row < lines.count else { return 0 }
        let line = lines[row]
        var end = line.count
        while end > 0, line[end - 1].glyph == Cell.blank.glyph { end -= 1 }
        return end
    }
}
