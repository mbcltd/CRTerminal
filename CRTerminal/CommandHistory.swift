import AppKit
import TerminalCore

/// One executed command, captured from a session's OSC 133 prompt marks.
struct CommandEntry: Equatable {
    let sessionID: UUID
    /// Stable per-session id (`PromptMark.sequence`) used to upsert.
    let sequence: Int
    let command: String
    let directory: String?
    var exitCode: Int?
    /// When this command was first observed (for display / approximate order).
    let timestamp: Date
    /// Global monotonic order across sessions (newest = largest).
    let order: Int
}

/// App-wide log of executed commands, fed from each session's prompt marks.
/// Independent of scrollback trimming, so history survives output scrolling
/// away. Backs the ⌘⇧K (current terminal) and ⌘⌥K (all terminals) palettes.
@MainActor
final class CommandHistoryStore {
    static let shared = CommandHistoryStore()

    private struct Key: Hashable { let session: UUID; let sequence: Int }

    private var entries: [CommandEntry] = []
    private var indexByKey: [Key: Int] = [:]
    private var nextOrder = 0
    private let limit = 5000

    /// Upsert every captured command in `marks` for `sessionID`. New commands
    /// append with a fresh timestamp/order; already-seen ones refresh their
    /// exit code (OSC 133;D arrives after the command was first observed).
    /// Idempotent and O(marks) — safe to call on every session update.
    func sync(sessionID: UUID, marks: [PromptMark]) {
        for mark in marks {
            guard let command = mark.command, let sequence = mark.sequence else { continue }
            let key = Key(session: sessionID, sequence: sequence)
            if let i = indexByKey[key] {
                entries[i].exitCode = mark.exitCode
            } else {
                entries.append(CommandEntry(
                    sessionID: sessionID, sequence: sequence, command: command,
                    directory: mark.directory, exitCode: mark.exitCode,
                    timestamp: Date(), order: nextOrder))
                indexByKey[key] = entries.count - 1
                nextOrder += 1
                trimIfNeeded()
            }
        }
    }

    /// Commands from one session, newest first, duplicate commands collapsed.
    func entries(forSession sessionID: UUID) -> [CommandEntry] {
        dedupe(entries.filter { $0.sessionID == sessionID }.sorted { $0.order > $1.order })
    }

    /// Commands across every session, newest first, duplicates collapsed.
    func allEntries() -> [CommandEntry] {
        dedupe(entries.sorted { $0.order > $1.order })
    }

    /// Test seam.
    func reset() {
        entries.removeAll()
        indexByKey.removeAll()
        nextOrder = 0
    }

    private func trimIfNeeded() {
        guard entries.count > limit else { return }
        entries.removeFirst(entries.count - limit)
        indexByKey.removeAll(keepingCapacity: true)
        for (i, entry) in entries.enumerated() {
            indexByKey[Key(session: entry.sessionID, sequence: entry.sequence)] = i
        }
    }

    /// Keep only the most-recent occurrence of each command string.
    private func dedupe(_ sortedNewestFirst: [CommandEntry]) -> [CommandEntry] {
        var seen = Set<String>()
        return sortedNewestFirst.filter { seen.insert($0.command).inserted }
    }
}

/// A command-history result for the palette: the command itself as the title,
/// directory · exit status (· terminal, in the all-terminals view) beneath.
struct CommandTarget: PaletteItem {
    let entry: CommandEntry
    let title: String
    let subtitle: String
    let facets: [SessionFacet]
}

/// Turns stored commands into `CommandTarget`s for the palette, mirroring
/// `JumpTargetBuilder`: the facets the search sees are also what's displayed.
@MainActor
enum CommandHistoryBuilder {
    /// Commands from a single session (no terminal label needed).
    static func targets(forSession sessionID: UUID) -> [CommandTarget] {
        CommandHistoryStore.shared.entries(forSession: sessionID).map {
            target(for: $0, sessionLabel: nil)
        }
    }

    /// Commands across all open terminals, each labelled by its session.
    static func targets(allAcross controllers: [TerminalWindowController]) -> [CommandTarget] {
        let labels = sessionLabels(across: controllers)
        return CommandHistoryStore.shared.allEntries().map {
            target(for: $0, sessionLabel: labels[$0.sessionID] ?? "closed session")
        }
    }

    private static func target(for entry: CommandEntry, sessionLabel: String?) -> CommandTarget {
        let dir = entry.directory.map { SessionInfo.abbreviate(path: $0) }
        var parts: [String] = []
        if let sessionLabel { parts.append(sessionLabel) }
        if let dir { parts.append(dir) }
        parts.append(statusGlyph(entry.exitCode))

        var facets = [SessionFacet(kind: "command", text: entry.command, weight: 1.5)]
        if let dir { facets.append(SessionFacet(kind: "directory", text: dir)) }
        if let sessionLabel { facets.append(SessionFacet(kind: "session", text: sessionLabel)) }

        return CommandTarget(
            entry: entry, title: entry.command,
            subtitle: parts.joined(separator: " · "), facets: facets)
    }

    private static func statusGlyph(_ exitCode: Int?) -> String {
        switch exitCode {
        case nil: return "…"
        case 0: return "✓"
        case let code?: return "✗ \(code)"
        }
    }

    private static func sessionLabels(
        across controllers: [TerminalWindowController]
    ) -> [UUID: String] {
        var labels: [UUID: String] = [:]
        let showWindow = controllers.count > 1
        for (windowIndex, controller) in controllers.enumerated() {
            for tab in controller.tabs {
                for pane in tab.panes {
                    guard let session = pane.session else { continue }
                    let name = session.snapshot.title
                        ?? SessionInfo.processName(of: session.shellProcessID) ?? "shell"
                    labels[pane.sessionID] = showWindow
                        ? "Window \(windowIndex + 1) · \(name)" : name
                }
            }
        }
        return labels
    }
}
