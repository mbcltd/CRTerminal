import CoreGraphics
import Foundation
import Testing
import TerminalCore
@testable import CRTerminal

/// Session restoration R1: the on-disk store writes/reads `.crtstate` files
/// keyed by session UUID and prunes orphans.
struct SessionStateStoreTests {
    /// A throwaway store rooted in a unique temp directory.
    private func makeStore() -> (store: SessionStateStore, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crtstate-test-" + UUID().uuidString)
        return (SessionStateStore(directory: directory), directory)
    }

    /// A small snapshot with recognisable content.
    private func sampleSnapshot(cwd: String? = "/tmp/work") -> TerminalStateSnapshot {
        var terminal = Terminal(columns: 40, rows: 10)
        terminal.feed(Array("restore me\r\nsecond line\r\n".utf8))
        return terminal.state.makeSnapshot(workingDirectoryHint: cwd)
    }

    @Test func savesAndLoadsByUUID() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let snapshot = sampleSnapshot()
        store.saveSynchronously(snapshot, for: id)

        let loaded = store.load(for: id)
        #expect(loaded == snapshot)
        #expect(loaded?.workingDirectoryHint == "/tmp/work")
        // Restoring the snapshot reproduces the text.
        let restored = TerminalState(restoring: try! #require(loaded))
        #expect(restored.lineText(0) == "restore me")
        #expect(restored.lineText(1) == "second line")
    }

    @Test func fileLandsAtUUIDPath() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        store.saveSynchronously(sampleSnapshot(), for: id)
        let url = store.url(for: id)
        #expect(url.lastPathComponent == "\(id.uuidString).crtstate")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func asyncSaveInvokesCompletionOnMain() async {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        await confirmation { confirmed in
            await withCheckedContinuation { continuation in
                store.save(sampleSnapshot(), for: id) {
                    confirmed()
                    continuation.resume()
                }
            }
        }
        #expect(store.load(for: id) != nil)
    }

    @Test func loadAllReturnsEveryStoredSession() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids = (0..<3).map { _ in UUID() }
        for id in ids { store.saveSynchronously(sampleSnapshot(), for: id) }
        let all = store.loadAll()
        #expect(Set(all.map(\.id)) == Set(ids))
    }

    @Test func missingStateLoadsAsNil() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.load(for: UUID()) == nil)
    }

    @Test func corruptFileLoadsAsNilWithoutThrowing() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        try Data("not a plist".utf8).write(to: store.url(for: id))
        #expect(store.load(for: id) == nil)
    }

    @Test func pruneOrphansKeepsOnlyLiveSessions() async {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keep = UUID()
        let drop = UUID()
        store.saveSynchronously(sampleSnapshot(), for: keep)
        store.saveSynchronously(sampleSnapshot(), for: drop)

        store.pruneOrphans(keeping: [keep])
        // Pruning runs on the io queue; let it drain.
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(store.load(for: keep) != nil)
        #expect(store.load(for: drop) == nil)
    }

    @Test func layoutSavesAndLoads() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let layout = LayoutSnapshot(windows: [
            WindowNode(
                frame: CGRect(x: 1, y: 2, width: 300, height: 400),
                activeTabIndex: 0,
                tabs: [TabNode(uuid: UUID(), presetName: "Dark",
                               root: .leaf(sessionID: UUID()))]),
        ])
        store.saveLayoutSynchronously(layout)
        #expect(store.loadLayout() == layout)
    }

    @Test func deleteAllRemovesContentsAndLayout() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.saveSynchronously(sampleSnapshot(), for: UUID())
        store.saveSynchronously(sampleSnapshot(), for: UUID())
        store.saveLayoutSynchronously(LayoutSnapshot(windows: []))
        store.deleteAll()
        let remaining = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path))?.filter {
            $0.hasSuffix(".crtstate") || $0.hasSuffix(".crtlayout")
        }
        #expect(remaining?.isEmpty == true)
        #expect(store.loadLayout() == nil)
    }

    @Test func discardRemovesState() async {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        store.saveSynchronously(sampleSnapshot(), for: id)
        store.discard(id: id)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.load(for: id) == nil)
    }
}
