import Foundation
import TerminalCore
import os

/// Persists the heavy per-session terminal contents (grid + scrollback,
/// ~1–13 MB each) to Application Support, keyed by session UUID, as our own
/// `.crtstate` files — never into the restoration plist (ARCHITECTURE.md
/// "session restoration", two-tier persistence). Lightweight window/tab/split
/// layout flows through `NSWindowRestoration` separately (R2/R3).
///
/// All disk I/O runs off the main thread on a utility queue.
final class SessionStateStore: Sendable {
    static let shared = SessionStateStore()

    static let fileExtension = "crtstate"

    private let directory: URL
    private let io = DispatchQueue(label: "crterminal.restore.io", qos: .utility)
    private let log = Logger(subsystem: "mbcltd.crterminal", category: "restore")

    /// `directory` is injectable so tests can use a scratch path.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base
                .appendingPathComponent("CRTerminal", isDirectory: true)
                .appendingPathComponent("Restore", isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: self.directory, withIntermediateDirectories: true)
    }

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString)
            .appendingPathExtension(Self.fileExtension)
    }

    /// Block until all queued disk I/O has completed. Used by tests for a
    /// deterministic barrier (the async `save`/`discard`/`pruneOrphans`
    /// otherwise race a fixed sleep). Safe from any thread — the io queue
    /// never calls back to the caller.
    nonisolated func flush() {
        io.sync {}
    }

    // MARK: Encode / decode

    private static func makeEncoder() -> PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }

    // MARK: Write

    /// Persist a snapshot off the main thread; `completion` fires on the main
    /// queue once the bytes are on disk (or the write failed).
    func save(
        _ snapshot: TerminalStateSnapshot, for id: UUID,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let url = url(for: id)
        io.async { [log] in
            do {
                let data = try Self.makeEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("save \(id, privacy: .public) failed: \(error, privacy: .public)")
            }
            if let completion {
                DispatchQueue.main.async { MainActor.assumeIsolated(completion) }
            }
        }
    }

    /// Synchronous write, for the quit path where we must finish before the
    /// process dies (used from R3's `applicationWillTerminate`).
    func saveSynchronously(_ snapshot: TerminalStateSnapshot, for id: UUID) {
        do {
            let data = try Self.makeEncoder().encode(snapshot)
            try data.write(to: url(for: id), options: .atomic)
        } catch {
            log.error("sync save \(id, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    // MARK: Read

    /// Decode the snapshot for a session id, or nil if absent/unreadable.
    /// A corrupt file never throws to the caller — it reads as "no state"
    /// (full corruption hardening lands in R4).
    func load(for id: UUID) -> TerminalStateSnapshot? {
        decode(at: url(for: id))
    }

    private func decode(at url: URL) -> TerminalStateSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try PropertyListDecoder().decode(TerminalStateSnapshot.self, from: data)
        } catch {
            log.error("decode \(url.lastPathComponent, privacy: .public) failed: \(error, privacy: .public)")
            return nil
        }
    }

    /// Every stored session, newest file first — drives the debug
    /// "restore last saved session" action before lifecycle wiring (R3).
    func loadAll() -> [(id: UUID, snapshot: TerminalStateSnapshot)] {
        storedFiles()
            .sorted { modificationDate(of: $0.url) > modificationDate(of: $1.url) }
            .compactMap { entry in
                decode(at: entry.url).map { (entry.id, $0) }
            }
    }

    // MARK: Layout (R2)

    private var layoutURL: URL {
        directory.appendingPathComponent("layout").appendingPathExtension("crtlayout")
    }

    /// Persist the window/tab/split layout tree. In R3 this moves into the
    /// `NSWindowRestoration` plist; for now it's its own file so the debug
    /// harness can drive the whole loop.
    func saveLayout(_ layout: LayoutSnapshot) {
        let url = layoutURL
        io.async { [log] in
            do {
                let data = try Self.makeEncoder().encode(layout)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("save layout failed: \(error, privacy: .public)")
            }
        }
    }

    /// Synchronous layout write for the quit path (must land before exit).
    func saveLayoutSynchronously(_ layout: LayoutSnapshot) {
        do {
            let data = try Self.makeEncoder().encode(layout)
            try data.write(to: layoutURL, options: .atomic)
        } catch {
            log.error("sync save layout failed: \(error, privacy: .public)")
        }
    }

    func loadLayout() -> LayoutSnapshot? {
        guard let data = try? Data(contentsOf: layoutURL) else { return nil }
        return try? PropertyListDecoder().decode(LayoutSnapshot.self, from: data)
    }

    /// Delete every stored file — session contents and the layout — when the
    /// user turns restoration off (`Never`), so nothing leaks to disk.
    /// Synchronous so a `Never` launch is clean immediately.
    func deleteAll() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        for url in urls where url.pathExtension == Self.fileExtension
            || url.pathExtension == "crtlayout" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Pruning

    /// Delete the state for one session (it's been restored or closed).
    func discard(id: UUID) {
        let url = url(for: id)
        io.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Remove every stored state whose UUID isn't in `liveIDs` — orphans from
    /// sessions that no longer exist. Wired into the lifecycle in R3; exposed
    /// now so the store owns its own housekeeping.
    func pruneOrphans(keeping liveIDs: Set<UUID>) {
        let files = storedFiles()
        io.async {
            for entry in files where !liveIDs.contains(entry.id) {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    // MARK: Enumeration

    private func storedFiles() -> [(id: UUID, url: URL)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == Self.fileExtension,
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            else { return nil }
            return (id, url)
        }
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
