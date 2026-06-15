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
    /// Absolute row where output begins (just past the echoed command); `nil`
    /// for an idle prompt. See `outputRange`.
    public var outputStartRow: Int?

    public init(rowRange: Range<Int>, command: String? = nil, directory: String? = nil,
                exitCode: Int? = nil, sequence: Int? = nil, outputStartRow: Int? = nil) {
        self.rowRange = rowRange
        self.command = command
        self.directory = directory
        self.exitCode = exitCode
        self.sequence = sequence
        self.outputStartRow = outputStartRow
    }

    /// Absolute rows holding just this command's output — the block minus its
    /// prompt and echoed command. `nil` at an idle prompt or when the command
    /// produced no rows.
    public var outputRange: Range<Int>? {
        guard let start = outputStartRow else { return nil }
        let lower = max(start, rowRange.lowerBound)
        guard lower < rowRange.upperBound else { return nil }
        return lower..<rowRange.upperBound
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
                sequence: mark.sequence,
                outputStartRow: mark.outputStartRow))
        }
        return result
    }

    /// The block whose span contains `row` (absolute), or `nil`. Used to target
    /// a block from a click point.
    public func block(atAbsoluteRow row: Int) -> Block? {
        blocks.first { $0.rowRange.contains(row) }
    }

    /// A block's output as text — body rows only, with the prompt and echoed
    /// command excluded and trailing blank lines trimmed. Empty when the block
    /// has no output (`outputRange == nil`).
    public func outputText(for block: Block) -> String {
        guard let range = block.outputRange else { return "" }
        var lines: [String] = []
        for row in range {
            guard let line = absoluteLine(row) else { continue }
            lines.append(Self.text(of: line))
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// A self-contained markdown rendering of a block — command, directory,
    /// exit code, and output — for export to the clipboard or a file. Returns
    /// "" for a block with nothing to show (an idle prompt). Local only: no
    /// account, no upload.
    public func markdownExport(for block: Block) -> String {
        var parts: [String] = []
        if let command = block.command {
            parts.append("### `\(command)`")
        }
        var meta: [String] = []
        if let directory = block.directory { meta.append("`\(directory)`") }
        if let exitCode = block.exitCode { meta.append("exit \(exitCode)") }
        if !meta.isEmpty { parts.append(meta.joined(separator: " · ")) }
        let output = outputText(for: block)
        if !output.isEmpty {
            // Fence longer than the longest backtick run in the output, so
            // output that itself contains ``` still nests cleanly.
            var longestRun = 0, current = 0
            for character in output {
                if character == "`" { current += 1; longestRun = max(longestRun, current) }
                else { current = 0 }
            }
            let fence = String(repeating: "`", count: max(3, longestRun + 1))
            parts.append("\(fence)\n\(output)\n\(fence)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Several blocks exported as one markdown document, separated by rules.
    /// Skips blocks that render empty.
    public func markdownExport(for blocks: [Block]) -> String {
        blocks.map { markdownExport(for: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")
    }
}
