import AppKit
import CRTRendering
import Sparkle
import SwiftUI
import TerminalCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) static var shared: AppDelegate?

    private var controllers: [TerminalWindowController] = []
    private var settingsWindow: NSWindow?
    private var previewRenderer: PresetPreviewRenderer?
    private var probe: TypistProbe?
    private var restoreProbe: RestoreProbe?

    /// Sparkle auto-updater. Started at launch; checks the SUFeedURL appcast
    /// declared in Info.plist and backs the "Check for Updates…" menu item.
    private var updaterController: SPUStandardUpdaterController?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Window restoration (R3) runs *before* applicationDidFinishLaunching
        // and rebuilds panes — so the bundled font must be registered now,
        // and the restoration mode must already be resolved.
        BundledFonts.register()
        // Probe / deterministic-override hook for the lifecycle tests; does
        // not persist, so it can't clobber the user's saved setting.
        if let raw = ProcessInfo.processInfo.environment["CRT_RESTORE_MODE"],
           let mode = RestorationMode(rawValue: raw) {
            SettingsStore.shared.overrideRestoration(mode)
        }
        // A Never launch starts clean and leaves nothing on disk.
        if SettingsStore.shared.settings.restoration == .never {
            SessionStateStore.shared.deleteAll()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start the updater before building the menu so the "Check for Updates…"
        // item can target it. `startingUpdater: true` also schedules the
        // background check governed by SUEnableAutomaticChecks.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        NSApp.mainMenu = makeMainMenu()
        NotificationPoster.shared.activate()
        SettingsStore.shared.onChange = { [weak self] in
            self?.settingsChanged()
        }
        AlertSettings.shared.onChange = { [weak self] in
            guard let self else { return }
            for controller in self.controllers {
                controller.refreshSessionMetadata()
            }
            self.refreshDockBadge()
        }

        // Restore from our own on-disk layout + content files. This is the
        // single restore path (AppKit window restoration is disabled), so it
        // works regardless of the system "Close windows when quitting"
        // preference. `System` mode consults that preference directly via
        // `shouldRestoreOnLaunch`; `Always` ignores it; `Never` is off.
        if controllers.isEmpty, shouldRestoreOnLaunch {
            restoreLayoutFromDisk()
        }

        let controller: TerminalWindowController
        if let restored = controllers.first {
            controller = restored
        } else {
            controller = makeWindowController()
            controller.window?.setFrameAutosaveName("MainWindow")
            controller.showWindow(nil)
        }
        // Drop content files for sessions that aren't alive — closed before
        // quit, or a clean launch that restored nothing — so none leak.
        pruneOrphanContents()
        NSApp.activate()

        if ProcessInfo.processInfo.environment["CRT_TYPIST"] != nil,
           let pane = controller.panes.first, let session = pane.session {
            probe = TypistProbe(view: pane, session: session)
            probe?.start()
        }
        if ProcessInfo.processInfo.environment["CRT_JUMP_PROBE"] != nil {
            runJumpProbe(controller: controller)
        }
        if ProcessInfo.processInfo.environment["CRT_RESTORE_PROBE"] != nil {
            restoreProbe = RestoreProbe(controller: controller)
            restoreProbe?.start()
        }
        if ProcessInfo.processInfo.environment["CRT_LAYOUT_PROBE"] != nil {
            runLayoutProbe(controller: controller)
        }
        if let phase = ProcessInfo.processInfo.environment["CRT_LIFECYCLE_PROBE"] {
            runLifecycleProbe(phase: phase, controller: controller)
        }
        if ProcessInfo.processInfo.environment["CRT_QUIT_LATENCY_PROBE"] != nil {
            runQuitLatencyProbe(controller: controller)
        }
    }

    /// End-to-end probe (CRT_JUMP_PROBE=1): opens the ⌘K palette over two
    /// live sessions, applies CRT_JUMP_QUERY, snapshots the panel to
    /// /tmp/crterminal-jump.png, dumps targets + the post-jump tab index to
    /// /tmp/crterminal-jump.txt, and exits.
    private func runJumpProbe(controller: TerminalWindowController) {
        let query = ProcessInfo.processInfo.environment["CRT_JUMP_QUERY"] ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            controller.addSession()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.showJumpMenu(nil)
                self.jumpMenu?.setQuery(query)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.jumpMenu?.writeSnapshot(to: "/tmp/crterminal-jump.png")
                    var report = JumpTargetBuilder.targets(across: self.controllers).map {
                        "\($0.title) | \($0.subtitle) | "
                            + $0.facets.map { "\($0.kind)=\($0.text)" }
                                .joined(separator: ", ")
                    }
                    report.append("results for query '\(query)': "
                        + "\(self.jumpMenu?.resultCount ?? -1)")
                    report.append("active tab before jump: \(controller.activeTabIndex)")
                    // Choose the top result (session 1; session 2 is active)
                    // and report where we landed.
                    self.jumpMenu?.choose(row: 0)
                    report.append("active tab after jump: \(controller.activeTabIndex)")
                    try? report.joined(separator: "\n").write(
                        toFile: "/tmp/crterminal-jump.txt", atomically: true, encoding: .utf8)
                    exit(0)
                }
            }
        }
    }

    /// End-to-end probe (CRT_LAYOUT_PROBE=1) for session restoration R2.
    /// Builds two windows — one with 3 tabs, the middle tab a 2×2 split —
    /// types a distinct marker and cwd into every pane, saves layout +
    /// contents, then rebuilds from disk into fresh windows and checks the
    /// structure, each pane's static text, and each cwd came back. Writes
    /// /tmp/crterminal-layout.txt and exits.
    private func runLayoutProbe(controller: TerminalWindowController) {
        // sessionID → (marker, directory) we expect to see after restore.
        var expected: [UUID: (marker: String, dir: String)] = [:]
        func seed(_ pane: TerminalView?, dir: String, marker: String) {
            guard let pane else { return }
            pane.send(Array("cd \(dir)\rprintf '\(marker)\\n'\r".utf8))
            expected[pane.sessionID] = (marker, dir)
        }
        func newest(in tab: SessionTab?) -> TerminalView? { tab?.panes.last }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // Window 1, tab 1: a lone pane.
            seed(controller.activeTab?.panes.first, dir: "/tmp", marker: "MARK_T1")

            // Window 1, tab 2: a 2×2 split (split right, then split each
            // column down).
            controller.addSession()
            let tab2 = controller.activeTab
            let b = newest(in: tab2)
            controller.window?.makeFirstResponder(b)
            controller.splitRight(nil)
            let c = newest(in: tab2)
            controller.window?.makeFirstResponder(b)
            controller.splitDown(nil)
            let e = newest(in: tab2)
            controller.window?.makeFirstResponder(c)
            controller.splitDown(nil)
            let f = newest(in: tab2)
            seed(b, dir: "/usr", marker: "MARK_2B")
            seed(c, dir: "/var", marker: "MARK_2C")
            seed(e, dir: "/etc", marker: "MARK_2E")
            seed(f, dir: "/bin", marker: "MARK_2F")

            // Window 1, tab 3: a lone pane.
            controller.addSession()
            seed(newest(in: controller.activeTab), dir: "/usr/lib", marker: "MARK_T3")

            // Window 2: a separate window with one pane.
            let window2 = self.makeWindowController()
            window2.showWindow(nil)
            seed(window2.activeTab?.panes.first, dir: "/usr/bin", marker: "MARK_W2")

            // Let every shell start and print its marker.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                self.finishLayoutProbe(expected: expected)
            }
        }
    }

    private func finishLayoutProbe(expected: [UUID: (marker: String, dir: String)]) {
        var report = ["=== CRT_LAYOUT REPORT ==="]

        // Save everything, capture the layout we expect to get back, then
        // rebuild into fresh windows.
        for controller in controllers { controller.saveAllContents() }
        let savedLayout = captureLayoutSnapshot()
        SessionStateStore.shared.saveLayout(savedLayout)
        report.append("saved windows: \(savedLayout.windows.count)")
        report.append("saved tabs: \(savedLayout.windows.map(\.tabs.count))")

        // Give the async content writes a beat to hit disk, then restore.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let restored = self.restoreLayoutFromDisk()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                report.append("restored windows: \(restored.count)")

                var paneCount = 0
                var markersOK = 0
                var markersTotal = 0
                var cwdOK = 0
                var maxPanesInATab = 0
                for controller in restored {
                    for tab in controller.tabs {
                        maxPanesInATab = max(maxPanesInATab, tab.panes.count)
                    }
                    for pane in controller.panes {
                        paneCount += 1
                        guard let want = expected[pane.sessionID],
                              let session = pane.session else { continue }
                        markersTotal += 1
                        let text = Self.gridText(session.snapshot)
                        if text.contains(where: { $0.contains(want.marker) }) {
                            markersOK += 1
                        }
                        let cwd = SessionInfo.workingDirectory(of: session.shellProcessID)
                        if Self.sameDirectory(cwd, want.dir) { cwdOK += 1 }
                    }
                }

                report.append("restored panes: \(paneCount) (expected \(expected.count))")
                report.append("largest restored tab: \(maxPanesInATab) panes (expect 4 for the 2×2)")
                report.append("markers restored: \(markersOK)/\(markersTotal)")
                report.append("cwds restored: \(cwdOK)/\(markersTotal)")

                // Structure: restored layout should match what we saved.
                let restoredLayout = LayoutSnapshot(
                    windows: restored.map { $0.captureLayout() })
                let shapeOK = Self.sameShape(savedLayout, restoredLayout)
                report.append("split-tree shape preserved: \(shapeOK)")

                // Frames restored across both windows (within a point).
                let framesOK = zip(savedLayout.windows, restoredLayout.windows)
                    .allSatisfy { saved, got in
                        abs(saved.frame.minX - got.frame.minX) < 1
                            && abs(saved.frame.minY - got.frame.minY) < 1
                            && abs(saved.frame.width - got.frame.width) < 1
                            && abs(saved.frame.height - got.frame.height) < 1
                    }
                report.append("window frames restored: \(framesOK)")

                let pass = restored.count == savedLayout.windows.count
                    && paneCount == expected.count
                    && maxPanesInATab == 4
                    && markersOK == markersTotal
                    && cwdOK == markersTotal
                    && shapeOK
                    && framesOK
                report.append("RESULT: \(pass ? "PASS" : "FAIL")")

                let text = (report + ["=== END REPORT ==="]).joined(separator: "\n") + "\n"
                FileHandle.standardError.write(Data(text.utf8))
                try? text.write(
                    toFile: "/tmp/crterminal-layout.txt", atomically: true, encoding: .utf8)
                exit(0)
            }
        }
    }

    /// Trailing-trimmed text of every scrollback + screen row.
    private static func gridText(_ state: TerminalState) -> [String] {
        func text(of row: [Cell]) -> String {
            var scalars = String.UnicodeScalarView()
            for cell in row where !cell.attributes.contains(.wideSpacer) {
                scalars.append(Unicode.Scalar(cell.glyph) ?? "\u{FFFD}")
            }
            var s = String(scalars)
            while s.hasSuffix(" ") { s.removeLast() }
            return s
        }
        return state.scrollback.map(text(of:)) + (0..<state.rows).map { state.lineText($0) }
    }

    /// cwds match modulo the /private symlink (/tmp == /private/tmp).
    private static func sameDirectory(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        let norm = { (p: String) in p.hasPrefix("/private") ? String(p.dropFirst(8)) : p }
        return norm(a) == norm(b)
    }

    /// Structural equality of two layouts: same window/tab counts and the
    /// same split nesting + session ids (ignoring divider fractions, which
    /// re-derive from live geometry).
    private static func sameShape(_ a: LayoutSnapshot, _ b: LayoutSnapshot) -> Bool {
        guard a.windows.count == b.windows.count else { return false }
        func sameNode(_ x: SplitNode, _ y: SplitNode) -> Bool {
            switch (x, y) {
            case let (.leaf(i), .leaf(j)):
                return i == j
            case let (.split(vx, _, cx), .split(vy, _, cy)):
                return vx == vy && cx.count == cy.count
                    && zip(cx, cy).allSatisfy { sameNode($0, $1) }
            default:
                return false
            }
        }
        return zip(a.windows, b.windows).allSatisfy { wa, wb in
            wa.tabs.count == wb.tabs.count
                && zip(wa.tabs, wb.tabs).allSatisfy { sameNode($0.root, $1.root) }
        }
    }

    // MARK: Lifecycle probe (R3)

    private static let lifecycleManifest = "/tmp/crterminal-lifecycle-manifest.json"
    private static let lifecycleReport = "/tmp/crterminal-lifecycle.txt"

    /// Cross-process probe for session restoration R3, run in phases sharing
    /// the on-disk store (see `Scripts/probe.sh lifecycle`):
    ///  • save — build windows, type markers, run the quit-time save, record a
    ///    manifest; exit.  • restore — a fresh launch (mode = Always) restores
    ///    from disk; verify the windows/contents/cwds came back.
    ///  • verify-never — a fresh launch (mode = Never) must be clean with no
    ///    files left on disk.
    private func runLifecycleProbe(phase: String, controller: TerminalWindowController) {
        switch phase {
        case "save": lifecycleSavePhase(controller: controller)
        case "restore": lifecycleVerifyPhase(restoring: true)
        case "verify-never": lifecycleVerifyPhase(restoring: false)
        default: writeLifecycleReport(["FAIL: unknown phase \(phase)"])
        }
    }

    private func lifecycleSavePhase(controller: TerminalWindowController) {
        var expected: [UUID: (marker: String, dir: String)] = [:]
        func seed(_ pane: TerminalView?, dir: String, marker: String) {
            guard let pane else { return }
            pane.send(Array("cd \(dir)\rprintf '\(marker)\\n'\r".utf8))
            expected[pane.sessionID] = (marker, dir)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // Window 1: tab 1 lone, tab 2 a left|right split.
            seed(controller.activeTab?.panes.first, dir: "/tmp", marker: "LIFE_T1")
            controller.addSession()
            let tab2 = controller.activeTab
            let left = tab2?.panes.last
            controller.window?.makeFirstResponder(left)
            controller.splitRight(nil)
            let right = tab2?.panes.last
            seed(left, dir: "/usr", marker: "LIFE_2L")
            seed(right, dir: "/var", marker: "LIFE_2R")
            // Window 2.
            let window2 = self.makeWindowController()
            window2.showWindow(nil)
            seed(window2.activeTab?.panes.first, dir: "/etc", marker: "LIFE_W2")

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                // The exact quit-time save path.
                self.saveStateForTermination()
                // Record what we expect to come back, keyed by session id.
                var manifest: [String: String] = [:]
                for (id, value) in expected {
                    manifest[id.uuidString] = "\(value.marker)|\(value.dir)"
                }
                if let data = try? JSONEncoder().encode(manifest) {
                    try? data.write(to: URL(fileURLWithPath: Self.lifecycleManifest))
                }
                self.writeLifecycleReport([
                    "phase: save",
                    "saved windows: \(self.controllers.count)",
                    "saved sessions: \(expected.count)",
                    "RESULT: SAVED",
                ])
            }
        }
    }

    private func lifecycleVerifyPhase(restoring: Bool) {
        // Give didFinishLaunching's restore (Always) a moment to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            var report = ["phase: \(restoring ? "restore" : "verify-never")"]
            let files = (try? FileManager.default.contentsOfDirectory(
                atPath: SessionStateStore.shared.url(for: UUID())
                    .deletingLastPathComponent().path)) ?? []
            let stateFiles = files.filter {
                $0.hasSuffix(".crtstate") || $0.hasSuffix(".crtlayout")
            }

            if restoring {
                let manifest = Self.loadManifest()
                var markersOK = 0, cwdOK = 0, total = 0
                var paneCount = 0, maxPanes = 0
                for controller in self.controllers {
                    for tab in controller.tabs {
                        maxPanes = max(maxPanes, tab.panes.count)
                    }
                    for pane in controller.panes {
                        paneCount += 1
                        guard let want = manifest[pane.sessionID],
                              let session = pane.session else { continue }
                        total += 1
                        let text = Self.gridText(session.snapshot)
                        if text.contains(where: { $0.contains(want.marker) }) { markersOK += 1 }
                        let cwd = SessionInfo.workingDirectory(of: session.shellProcessID)
                        if Self.sameDirectory(cwd, want.dir) { cwdOK += 1 }
                    }
                }
                report.append("restored windows: \(self.controllers.count)")
                report.append("restored panes: \(paneCount) (expected \(manifest.count))")
                report.append("largest tab: \(maxPanes) panes (expect 2 for the split)")
                report.append("markers restored: \(markersOK)/\(total)")
                report.append("cwds restored: \(cwdOK)/\(total)")
                let pass = self.controllers.count == 2
                    && paneCount == manifest.count
                    && maxPanes == 2
                    && markersOK == total && total == manifest.count
                    && cwdOK == total
                report.append("RESULT: \(pass ? "PASS" : "FAIL")")
            } else {
                // Never: a single clean window, nothing on disk.
                report.append("windows: \(self.controllers.count) (expect 1)")
                report.append("tabs in window: \(self.controllers.first?.tabs.count ?? -1)")
                report.append("state files on disk: \(stateFiles.count) \(stateFiles)")
                let pass = self.controllers.count == 1
                    && self.controllers.first?.tabs.count == 1
                    && stateFiles.isEmpty
                report.append("RESULT: \(pass ? "PASS" : "FAIL")")
            }
            self.writeLifecycleReport(report)
        }
    }

    private static func loadManifest() -> [UUID: (marker: String, dir: String)] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: lifecycleManifest)),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        var result: [UUID: (String, String)] = [:]
        for (key, value) in raw {
            let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
            if let id = UUID(uuidString: key), parts.count == 2 {
                result[id] = (parts[0], parts[1])
            }
        }
        return result
    }

    private func writeLifecycleReport(_ lines: [String]) {
        let text = (["=== CRT_LIFECYCLE REPORT ==="] + lines + ["=== END REPORT ==="])
            .joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(text.utf8))
        try? text.write(toFile: Self.lifecycleReport, atomically: true, encoding: .utf8)
        exit(0)
    }

    // MARK: Quit-latency probe (R4)

    /// Measures the synchronous quit-time save (`saveStateForTermination`)
    /// with several large sessions (R4 exit: restoration adds no measurable
    /// quit delay). Reports a "cold" save (everything dirty) and a "warm"
    /// save (nothing changed since — the realistic quit, where the debounce
    /// already wrote the contents and the generation-skip elides every
    /// session). Writes /tmp/crterminal-quit-latency.txt.
    private func runQuitLatencyProbe(controller: TerminalWindowController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            for i in 0..<6 {
                if i > 0 { controller.addSession() }
                // Fill the scrollback (caps at 10k) with cheap output.
                controller.activeTab?.panes.first?.send(Array("seq 1 20000\r".utf8))
            }
            self.waitForQuiescence(lastTotal: 0, stableTicks: 0, ticks: 0)
        }
    }

    private var allPanes: [TerminalView] { controllers.flatMap(\.panes) }

    /// Poll until the grids stop changing (output fully drained), so the
    /// measurement isn't polluted by in-flight `seq` output. Caps the wait so
    /// it always reports.
    private func waitForQuiescence(lastTotal: UInt64, stableTicks: Int, ticks: Int) {
        let total = allPanes.reduce(UInt64(0)) { $0 + ($1.session?.snapshot.generation ?? 0) }
        if (total == lastTotal && stableTicks >= 2) || ticks > 40 {
            finishQuitLatencyProbe()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.waitForQuiescence(
                lastTotal: total,
                stableTicks: total == lastTotal ? stableTicks + 1 : 0,
                ticks: ticks + 1)
        }
    }

    private func finishQuitLatencyProbe() {
        // Worst case: pretend nothing was saved yet, so every session's
        // contents are written synchronously.
        for pane in allPanes { pane.lastSavedGeneration = nil }
        let full = Self.milliseconds { self.saveStateForTermination() }
        // Realistic quit: nothing changed since the previous save, so the
        // generation-skip elides every session.
        let warm = Self.milliseconds { self.saveStateForTermination() }
        let bytes = SessionStateStore.shared.totalStoredBytes()
        let report = [
            "=== CRT_QUIT_LATENCY REPORT ===",
            "windows: \(controllers.count), panes/window: \(controllers.map(\.panes.count))",
            "sessions: \(allPanes.count)",
            "stored bytes: \(bytes / 1_000_000) MB",
            String(format: "full save (all sessions dirty, worst case): %.1f ms", full),
            String(format: "warm save (unchanged, models real quit): %.2f ms", warm),
            "RESULT: \(warm < 5 ? "PASS" : "CHECK") (warm save under 5 ms)",
            "=== END REPORT ===",
        ].joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(report.utf8))
        try? report.write(
            toFile: "/tmp/crterminal-quit-latency.txt",
            atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func milliseconds(_ body: () -> Void) -> Double {
        let start = Date()
        body()
        return Date().timeIntervalSince(start) * 1000
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Persist *before* tearing down: the shells are still alive, so cwds
        // can be read (proc_pidinfo) before SIGHUP, and synchronous writes
        // finish before the process exits.
        saveStateForTermination()
        for controller in controllers {
            for pane in controller.panes {
                pane.session?.terminate()
            }
        }
    }

    /// Whether this launch should restore the previous session. `Never` never
    /// does, `Always` always does, and `System` follows the macOS "Close
    /// windows when quitting an application" preference — the global
    /// `NSQuitAlwaysKeepsWindows` default (true ⇒ keep/restore). Reading it
    /// directly (rather than waiting for AppKit's restoration callback, which
    /// only fires under that same preference but unreliably) lets us drive the
    /// reliable on-disk path while still honouring the user's system choice.
    var shouldRestoreOnLaunch: Bool {
        Self.shouldRestore(
            mode: SettingsStore.shared.settings.restoration,
            systemKeepsWindows: UserDefaults.standard.bool(forKey: "NSQuitAlwaysKeepsWindows"))
    }

    /// Pure restore decision (unit-tested): `Never` off, `Always` on, `System`
    /// follows the macOS "keep windows when quitting" preference.
    static func shouldRestore(mode: RestorationMode, systemKeepsWindows: Bool) -> Bool {
        switch mode {
        case .never: return false
        case .always: return true
        case .system: return systemKeepsWindows
        }
    }

    /// Quit-time save of every window's layout + contents (R3). `Never`
    /// instead wipes any stored state so nothing is left behind.
    func saveStateForTermination() {
        guard SettingsStore.shared.restorationEnabled else {
            SessionStateStore.shared.deleteAll()
            return
        }
        for controller in controllers {
            controller.saveAllContents(synchronously: true)
        }
        // The on-disk layout is our single source of truth for restore, in
        // every enabled mode (System included) — so it must always be written.
        SessionStateStore.shared.saveLayoutSynchronously(captureLayoutSnapshot())
        // The generation-skip may have elided sessions whose only write was an
        // async debounce; drain the io queue so every file is on disk before
        // the process exits.
        SessionStateStore.shared.flush()
    }

    // MARK: Coalesced restoration save (significant-change debounce)

    private var restorationSaveWork: DispatchWorkItem?

    /// A layout-affecting change happened; coalesce a save ~2 s later so a
    /// crash loses little without thrashing the disk on every keystroke.
    func setNeedsRestorationSave() {
        guard SettingsStore.shared.restorationEnabled else { return }
        restorationSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for controller in self.controllers { controller.saveAllContents() }
            // Always persist the layout (the restore source of truth) so a
            // crash before the next quit still comes back, in every mode.
            SessionStateStore.shared.saveLayout(self.captureLayoutSnapshot())
        }
        restorationSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Delete `.crtstate` files for sessions that are no longer alive.
    func pruneOrphanContents() {
        guard SettingsStore.shared.restorationEnabled else { return }
        let live = Set(controllers.flatMap { $0.liveSessionIDs })
        SessionStateStore.shared.pruneOrphans(keeping: live)
    }

    /// React to a restoration-mode change: wipe stored state (`Never`) or
    /// schedule a fresh save so the on-disk layout reflects the new mode.
    private func applyRestorationMode() {
        if SettingsStore.shared.restorationEnabled {
            setNeedsRestorationSave()
        } else {
            restorationSaveWork?.cancel()
            SessionStateStore.shared.deleteAll()
        }
    }

    /// NSWindowRestoration callback (via `WindowRestoration`). AppKit window
    /// restoration is no longer used — restore is driven from our own on-disk
    /// layout in `applicationDidFinishLaunching` — so this only fires for
    /// *stale* saved state left by older builds, and must not revive a window
    /// (that would duplicate what the disk path restores).
    func restoreWindow(
        identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
        completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
    ) {
        completionHandler(nil, nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Windows & tabs

    func makeWindowController(spawnInitialSession: Bool = true) -> TerminalWindowController {
        let controller = TerminalWindowController(
            settings: SettingsStore.shared.settings,
            spawnInitialSession: spawnInitialSession)
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
            self?.refreshDockBadge()
        }
        controller.onSignificantChange = { [weak self] in
            self?.setNeedsRestorationSave()
        }
        controllers.append(controller)
        return controller
    }

    // MARK: Dock badge

    /// Sessions with unseen bells, summed across every window. Called by
    /// each window's metadata tick and on every attention change, so
    /// closes and cross-window session moves correct it within a second.
    func refreshDockBadge() {
        let count = AlertSettings.shared.dockBadge
            ? controllers.reduce(0) { $0 + $1.attentionSessionCount } : 0
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    /// A bell arrived while the app is inactive. The badge follows via
    /// refreshDockBadge; the single dock bounce is opt-in.
    func bellRequiresAttention() {
        if !NSApp.isActive, AlertSettings.shared.dockBounce {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    // MARK: Session dragging

    /// A sidebar drop landed on `destination`: move the dragged session
    /// there, detaching it from whichever window holds it. Returns false
    /// when the session isn't in any registered window (the sidebar then
    /// falls back to a local reorder).
    func moveSession(
        id: UUID, to destination: TerminalWindowController, at gapIndex: Int
    ) -> Bool {
        guard let source = controllers.first(where: { controller in
            controller.tabs.contains { $0.id == id }
        }) else { return false }
        if source === destination {
            return destination.reorderSession(id: id, to: gapIndex)
        }
        guard let tab = source.detachSession(id: id) else { return false }
        destination.adopt(tab: tab, at: gapIndex)
        return true
    }

    /// A session drag ended on no drop target. Outside every terminal
    /// window that's a tear-off — the session moves into a fresh window at
    /// the drop point. Inside a window it's just a cancelled drag.
    func sessionDragEnded(id: UUID, droppedAt screenPoint: NSPoint) {
        guard !controllers.contains(where: {
            $0.window?.frame.contains(screenPoint) == true
        }) else { return }
        guard let source = controllers.first(where: { controller in
            controller.tabs.contains { $0.id == id }
        }) else { return }
        let topLeft = NSPoint(x: screenPoint.x - 60, y: screenPoint.y + 20)
        // Tearing off a window's only session would recreate the same
        // window, so just move it to the drop point.
        if source.tabs.count == 1 {
            source.window?.setFrameTopLeftPoint(topLeft)
            return
        }
        guard let tab = source.detachSession(id: id) else { return }
        let controller = makeWindowController(spawnInitialSession: false)
        // Keep the source window's size so the torn-off grid doesn't reflow.
        if let frame = source.window?.frame, let window = controller.window {
            window.setFrame(NSRect(origin: window.frame.origin, size: frame.size),
                            display: false)
        }
        controller.adopt(tab: tab, at: 0)
        controller.window?.setFrameTopLeftPoint(topLeft)
        controller.showWindow(nil)
    }

    private var keyController: TerminalWindowController? {
        NSApp.keyWindow?.windowController as? TerminalWindowController
            ?? controllers.last
    }

    @objc private func newWindow(_ sender: Any?) {
        makeWindowController().showWindow(sender)
    }

    @objc private func newSession(_ sender: Any?) {
        if let key = keyController {
            key.addSession()
        } else {
            newWindow(sender)
        }
    }

    @objc private func jumpToSession(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        keyController?.selectTab(index)
    }

    // MARK: Jump menu (⌘K)

    private var jumpMenu: PaletteController<JumpTarget>?

    /// ⌘K toggles a palette searching every session in every window.
    @objc private func showJumpMenu(_ sender: Any?) {
        if let jumpMenu {
            jumpMenu.dismiss()
            return
        }
        let targets = JumpTargetBuilder.targets(across: controllers)
        guard !targets.isEmpty else { return }
        let menu = PaletteController(targets: targets, theme: paletteTheme) { [weak self] target in
            self?.jump(to: target)
        }
        menu.onDismiss = { [weak self] in self?.jumpMenu = nil }
        jumpMenu = menu
        menu.show(over: NSApp.keyWindow)
    }

    private func jump(to target: JumpTarget) {
        focusSession(id: target.tabID)
    }

    // MARK: Command history (⌘⇧K current terminal, ⌘⌥K all terminals)

    private var commandPalette: PaletteController<CommandTarget>?

    /// ⌘⇧K: recall a command from the focused terminal's history.
    @objc private func showCommandHistory(_ sender: Any?) {
        if commandPalette != nil { commandPalette?.dismiss(); return }
        guard let pane = keyController?.focusedPane else { return }
        presentCommandPalette(
            targets: CommandHistoryBuilder.targets(forSession: pane.sessionID),
            placeholder: "Search command history…", into: pane)
    }

    /// ⌘⌥K: recall a command from every terminal's history.
    @objc private func showAllCommandHistory(_ sender: Any?) {
        if commandPalette != nil { commandPalette?.dismiss(); return }
        guard let pane = keyController?.focusedPane else { return }
        presentCommandPalette(
            targets: CommandHistoryBuilder.targets(allAcross: controllers),
            placeholder: "Search all command history…", into: pane)
    }

    /// Shows the command palette over the focused window and, on selection,
    /// types the chosen command at that terminal's prompt (no newline — the
    /// user edits then runs it, Ctrl-R style).
    private func presentCommandPalette(
        targets: [CommandTarget], placeholder: String, into pane: TerminalView
    ) {
        guard !targets.isEmpty else { return }
        let hostWindow = NSApp.keyWindow
        let palette = PaletteController(
            targets: targets, theme: paletteTheme,
            placeholder: placeholder, emptyText: "No matching commands"
        ) { [weak pane] target in
            pane?.window?.makeKeyAndOrderFront(nil)
            if let pane { pane.window?.makeFirstResponder(pane) }
            pane?.send(Array(target.entry.command.utf8))
        }
        palette.onDismiss = { [weak self] in self?.commandPalette = nil }
        commandPalette = palette
        palette.show(over: hostWindow)
    }

    /// The active session's theme (or the global default) for palette chrome.
    private var paletteTheme: SidebarTheme {
        SidebarTheme(
            preset: keyController?.activePreset
                ?? SettingsStore.shared.settings.preset(in: PresetCatalog.all))
    }

    /// Lands on a session wherever it lives: activates the app, fronts
    /// the owning window, selects the tab. Notification taps and the ⌘K
    /// palette both end here.
    func focusSession(id: UUID) {
        guard let controller = controllers.first(where: { controller in
            controller.tabs.contains { $0.id == id }
        }), let index = controller.tabs.firstIndex(where: { $0.id == id })
        else { return }
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.selectTab(index)
    }

    private func settingsChanged() {
        let settings = SettingsStore.shared.settings
        for controller in controllers {
            controller.apply(settings: settings)
        }
        applyRestorationMode()
    }

    // MARK: CRT presets

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let preset = PresetCatalog.all.first(where: { $0.name == name })
        else { return }
        // Themes the active session only; the default theme (for new
        // sessions and windows) is set in Settings, not by this switch.
        keyController?.apply(preset: preset)
    }

    // MARK: Full-layout restoration (R2)

    /// The layout tree for every open window (frames, tabs, split nesting).
    func captureLayoutSnapshot() -> LayoutSnapshot {
        LayoutSnapshot(windows: controllers.map { $0.captureLayout() })
    }

    /// Rebuild the saved windows: one fresh controller per window node, each
    /// reconstructing its tabs/splits and restoring every pane.
    @discardableResult
    func restoreLayoutFromDisk(show: Bool = true) -> [TerminalWindowController] {
        guard let layout = SessionStateStore.shared.loadLayout(),
              !layout.windows.isEmpty else { return [] }
        var restored: [TerminalWindowController] = []
        for windowNode in layout.windows {
            let controller = makeWindowController(spawnInitialSession: false)
            controller.restoreLayout(windowNode, contents: SessionStateStore.shared)
            if show { controller.showWindow(nil) }
            restored.append(controller)
        }
        return restored
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let preview = PresetPreviewRenderer()
            previewRenderer = preview
            let window = NSWindow(
                contentViewController: NSHostingController(
                    rootView: SettingsView(preview: preview)))
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("Settings")
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(sender)
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        let credits = NSMutableAttributedString()
        let link = NSAttributedString(
            string: "morgan-brown.com",
            attributes: [
                .link: URL(string: "https://morgan-brown.com")!,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            ])
        credits.append(link)

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectPreset(_:)) {
            let current = keyController?.currentPresetName
                ?? SettingsStore.shared.settings.presetName
            menuItem.state = (menuItem.representedObject as? String) == current
                ? .on : .off
        }
        if menuItem.action == #selector(jumpToSession(_:)) {
            guard let index = menuItem.representedObject as? Int,
                  let controller = keyController,
                  index < controller.tabs.count else { return false }
            menuItem.state = index == controller.activeTabIndex ? .on : .off
        }
        return true
    }

    // MARK: Menu

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        let about = appMenu.addItem(
            withTitle: "About crterm",
            action: #selector(showAboutPanel(_:)),
            keyEquivalent: "")
        about.target = self
        let updates = appMenu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "")
        updates.target = updaterController
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(
            withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide crterm",
            action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit crterm",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let shellMenu = NSMenu(title: "Shell")
        let newWindowItem = shellMenu.addItem(
            withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newWindowItem.target = self
        let newSessionItem = shellMenu.addItem(
            withTitle: "New Session", action: #selector(newSession(_:)), keyEquivalent: "t")
        newSessionItem.target = self
        let nextSession = shellMenu.addItem(
            withTitle: "Next Session",
            action: #selector(TerminalWindowController.nextSession(_:)), keyEquivalent: "]")
        nextSession.keyEquivalentModifierMask = [.command, .shift]
        let previousSession = shellMenu.addItem(
            withTitle: "Previous Session",
            action: #selector(TerminalWindowController.previousSession(_:)), keyEquivalent: "[")
        previousSession.keyEquivalentModifierMask = [.command, .shift]
        let jumpMenuItem = shellMenu.addItem(
            withTitle: "Jump to Session…",
            action: #selector(showJumpMenu(_:)), keyEquivalent: "k")
        jumpMenuItem.target = self
        let commandHistoryItem = shellMenu.addItem(
            withTitle: "Search Command History…",
            action: #selector(showCommandHistory(_:)), keyEquivalent: "k")
        commandHistoryItem.keyEquivalentModifierMask = [.command, .shift]
        commandHistoryItem.target = self
        let allCommandHistoryItem = shellMenu.addItem(
            withTitle: "Search All Command History…",
            action: #selector(showAllCommandHistory(_:)), keyEquivalent: "k")
        allCommandHistoryItem.keyEquivalentModifierMask = [.command, .option]
        allCommandHistoryItem.target = self
        shellMenu.addItem(.separator())
        shellMenu.addItem(
            withTitle: "Split Right",
            action: #selector(TerminalWindowController.splitRight(_:)), keyEquivalent: "d")
        let splitDown = shellMenu.addItem(
            withTitle: "Split Down",
            action: #selector(TerminalWindowController.splitDown(_:)), keyEquivalent: "d")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(.separator())
        shellMenu.addItem(
            withTitle: "Close Pane",
            action: #selector(TerminalWindowController.closePane(_:)), keyEquivalent: "w")
        let shellMenuItem = NSMenuItem()
        shellMenuItem.submenu = shellMenu
        mainMenu.addItem(shellMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        // Nil target → the responder chain handles it: the search field's
        // field editor when the find bar is focused. Without this item ⌘A is
        // dead in every text field, since AppKit only wires the shortcut up
        // through the menu.
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Find…",
            action: #selector(TerminalWindowController.toggleSearch(_:)), keyEquivalent: "f")
        editMenu.addItem(
            withTitle: "Find Next",
            action: #selector(TerminalWindowController.findNext(_:)), keyEquivalent: "g")
        let findPrevious = editMenu.addItem(
            withTitle: "Find Previous",
            action: #selector(TerminalWindowController.findPrevious(_:)), keyEquivalent: "g")
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenu = NSMenu(title: "View")
        for (index, preset) in PresetCatalog.all.enumerated() {
            // ⌃⌘1-9; sessions own plain ⌘1-9 (macOS tab convention).
            let item = viewMenu.addItem(
                withTitle: preset.name,
                action: #selector(selectPreset(_:)),
                keyEquivalent: index < 9 ? String(index + 1) : "")
            item.keyEquivalentModifierMask = [.command, .control]
            item.target = self
            item.representedObject = preset.name
        }
        viewMenu.addItem(.separator())
        let previousPrompt = viewMenu.addItem(
            withTitle: "Jump to Previous Prompt",
            action: #selector(TerminalView.jumpToPreviousPrompt(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        previousPrompt.keyEquivalentModifierMask = [.command]
        let nextPrompt = viewMenu.addItem(
            withTitle: "Jump to Next Prompt",
            action: #selector(TerminalView.jumpToNextPrompt(_:)),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        nextPrompt.keyEquivalentModifierMask = [.command]
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        for index in 0..<9 {
            let item = windowMenu.addItem(
                withTitle: "Session \(index + 1)",
                action: #selector(jumpToSession(_:)),
                keyEquivalent: String(index + 1))
            item.target = self
            item.representedObject = index
        }
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}
