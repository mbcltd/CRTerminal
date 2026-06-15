/// A command block: one segment of the output stream, spanning a shell prompt,
/// the command typed at it, and that command's output — Warp-style "blocks", but
/// derived locally from the OSC 133 prompt marks the parser already captures.
///
/// Blocks are a *projection*, not stored state (see `TerminalState.blocks`): a
/// block is simply the span between two consecutive `PromptMark`s, so it inherits
/// the marks' reflow/trim correctness for free and adds no new parsing.
public struct Block: Sendable, Equatable {
    /// Absolute row span (half-open): the prompt's first row, through the output,
    /// up to the next block's first row (or the bottom of the live screen for the
    /// last block). Rows are scrollback-stable absolute indices, like `PromptMark.row`.
    public var rowRange: Range<Int>
    /// The command typed at this prompt (captured between OSC 133;B and ;C);
    /// `nil` for an idle prompt where nothing has run yet, or when shell
    /// integration omits ;B/;C.
    public var command: String?
    /// Working directory (OSC 7) when the command started, if known.
    public var directory: String?
    /// Exit code reported by OSC 133;D; `nil` while the command is still running
    /// or at an idle prompt.
    public var exitCode: Int?
    /// Stable per-session id mirroring `PromptMark.sequence`; `nil` until a
    /// command runs. Lets callers track a block across reflow/trim.
    public var sequence: Int?

    public init(rowRange: Range<Int>, command: String? = nil, directory: String? = nil,
                exitCode: Int? = nil, sequence: Int? = nil) {
        self.rowRange = rowRange
        self.command = command
        self.directory = directory
        self.exitCode = exitCode
        self.sequence = sequence
    }

    public enum Status: Sendable, Equatable, Hashable {
        /// Sitting at a prompt with nothing run yet.
        case prompt
        /// A command was issued but has not reported completion.
        case running
        /// The command finished with the given exit code.
        case finished(exitCode: Int)
    }

    public var status: Status {
        if let exitCode { return .finished(exitCode: exitCode) }
        if command != nil { return .running }
        return .prompt
    }

    /// `true`/`false` once the command has finished, `nil` while running or idle.
    /// Drives the per-block status gutter (green/red) in the renderer.
    public var succeeded: Bool? {
        guard let exitCode else { return nil }
        return exitCode == 0
    }
}

extension TerminalState {
    /// The output stream segmented into command blocks, derived from `promptMarks`.
    ///
    /// Block `i` spans from `promptMarks[i].row` up to the next mark's row (the
    /// last block runs to the bottom of the live screen). Empty when shell
    /// integration is off (no marks) or while the alternate screen is active —
    /// full-screen apps (vim, htop, tmux) emit no marks, so the whole session is
    /// one implicit block and callers fall back to the flat grid.
    public var blocks: [Block] {
        guard !isAlternateScreen, !promptMarks.isEmpty else { return [] }
        let bottom = absoluteScreenTop + rows  // exclusive end of the live screen
        var result: [Block] = []
        result.reserveCapacity(promptMarks.count)
        for (i, mark) in promptMarks.enumerated() {
            let end = i + 1 < promptMarks.count ? promptMarks[i + 1].row : bottom
            // Marks are ascending and distinct, so this normally holds; guard
            // against a mark momentarily at/below the screen bottom.
            guard mark.row < end else { continue }
            result.append(Block(
                rowRange: mark.row..<end,
                command: mark.command,
                directory: mark.directory,
                exitCode: mark.exitCode,
                sequence: mark.sequence))
        }
        return result
    }
}
