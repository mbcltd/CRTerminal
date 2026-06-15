import Foundation
import Testing
import TerminalCore
@testable import CRTerminal

private func mark(_ command: String, sequence: Int, exit: Int? = nil,
                  directory: String? = nil) -> PromptMark {
    PromptMark(row: sequence, exitCode: exit, command: command,
               directory: directory, sequence: sequence)
}

@MainActor
struct CommandHistoryStoreTests {
    @Test func ingestsCapturedCommandsNewestFirst() {
        let store = CommandHistoryStore()
        let session = UUID()
        store.sync(sessionID: session, marks: [
            mark("git status", sequence: 0, exit: 0),
            mark("make build", sequence: 1, exit: 0),
        ])
        #expect(store.entries(forSession: session).map(\.command) == ["make build", "git status"])
    }

    @Test func ignoresMarksWithoutCapturedText() {
        let store = CommandHistoryStore()
        let session = UUID()
        store.sync(sessionID: session, marks: [
            PromptMark(row: 0),                              // bare prompt, no command
            mark("ls", sequence: 0, exit: 0),
        ])
        #expect(store.entries(forSession: session).map(\.command) == ["ls"])
    }

    @Test func refreshesExitCodeOnLaterSync() {
        let store = CommandHistoryStore()
        let session = UUID()
        store.sync(sessionID: session, marks: [mark("sleep 1", sequence: 0)])      // running
        #expect(store.entries(forSession: session).first?.exitCode == nil)
        store.sync(sessionID: session, marks: [mark("sleep 1", sequence: 0, exit: 0)])  // D arrives
        #expect(store.entries(forSession: session).first?.exitCode == 0)
        // No duplicate created by the second sync.
        #expect(store.entries(forSession: session).count == 1)
    }

    @Test func filtersBySessionAndMergesAcrossSessions() {
        let store = CommandHistoryStore()
        let a = UUID(), b = UUID()
        store.sync(sessionID: a, marks: [mark("a1", sequence: 0)])
        store.sync(sessionID: b, marks: [mark("b1", sequence: 0)])
        store.sync(sessionID: a, marks: [mark("a1", sequence: 0), mark("a2", sequence: 1)])
        #expect(store.entries(forSession: a).map(\.command) == ["a2", "a1"])
        #expect(store.entries(forSession: b).map(\.command) == ["b1"])
        // Global order: a1, b1, a2 ingested → newest first.
        #expect(store.allEntries().map(\.command) == ["a2", "b1", "a1"])
    }

    @Test func collapsesDuplicateCommandsKeepingMostRecent() {
        let store = CommandHistoryStore()
        let session = UUID()
        store.sync(sessionID: session, marks: [
            mark("ls", sequence: 0, exit: 0),
            mark("vim", sequence: 1, exit: 0),
            mark("ls", sequence: 2, exit: 1),     // re-run, failed this time
        ])
        let entries = store.entries(forSession: session)
        #expect(entries.map(\.command) == ["ls", "vim"])
        #expect(entries.first?.exitCode == 1)     // the most recent "ls"
    }
}

@MainActor
struct CommandTargetSearchTests {
    private func target(_ command: String, directory: String? = nil) -> CommandTarget {
        var facets = [SessionFacet(kind: "command", text: command, weight: 1.5)]
        if let directory { facets.append(SessionFacet(kind: "directory", text: directory)) }
        return CommandTarget(
            entry: CommandEntry(sessionID: UUID(), sequence: 0, command: command,
                                directory: directory, exitCode: 0,
                                timestamp: Date(), order: 0),
            title: command, subtitle: directory ?? "", facets: facets)
    }

    @Test func smartSearchMatchesCommandAndDirectoryFacets() {
        let targets = [
            target("git rebase -i main", directory: "~/proj"),
            target("npm test", directory: "~/web"),
            target("git status", directory: "~/proj"),
        ]
        // Token-AND across facets: "git" (command) + "proj" (directory).
        #expect(JumpSearch.rank(targets, query: "git proj").map(\.title)
            == ["git rebase -i main", "git status"])
        #expect(JumpSearch.rank(targets, query: "npm").map(\.title) == ["npm test"])
        #expect(JumpSearch.rank(targets, query: "nomatch").isEmpty)
    }
}
