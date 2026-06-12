import AppKit
import CRTRendering
import TerminalCore
import Testing
@testable import CRTerminal

struct SidebarThemeTests {
    @Test @MainActor func monochromePresetsTintEverythingWithThePhosphor() {
        var preset = CRTPreset(name: "Amber", effects: true)
        preset.phosphor = .init(
            color: HexColor(0xFF, 0xB0, 0x00), decayMs: 5, monochrome: true)
        let theme = SidebarTheme(preset: preset)
        #expect(theme.green == theme.accent)
        #expect(theme.amber == theme.accent)
    }

    @Test @MainActor func colorPresetsKeepConventionalStatusColors() {
        var preset = CRTPreset(name: "Composite", effects: true)
        preset.phosphor = .init(
            color: HexColor(0xFF, 0xFF, 0xFF), decayMs: 2, monochrome: false)
        let theme = SidebarTheme(preset: preset)
        #expect(theme.green != theme.accent)
    }
}

/// Serialized: these spawn real PTY children, and concurrent forks from a
/// multithreaded test host can wedge a child between fork and exec (seen
/// as a cwd-poll timeout on CI runners).
@Suite(.serialized) struct SessionInfoTests {
    @Test func abbreviatesHomePaths() {
        let home = NSHomeDirectory()
        #expect(SessionInfo.abbreviate(path: home) == "~")
        #expect(SessionInfo.abbreviate(path: home + "/dev/app") == "~/dev/app")
        #expect(SessionInfo.abbreviate(path: "/tmp") == "/tmp")
    }

    @Test func displayNameIsJustTheDirectory() {
        let home = NSHomeDirectory()
        #expect(SessionInfo.displayName(path: home + "/Documents/dev/kmono") == "kmono")
        #expect(SessionInfo.displayName(path: home) == "~")
        #expect(SessionInfo.displayName(path: "/") == "/")
    }

    @Test func readsOwnWorkingDirectoryAndName() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let cwd = SessionInfo.workingDirectory(of: pid)
        #expect(cwd == FileManager.default.currentDirectoryPath)
        #expect(SessionInfo.processName(of: pid)?.isEmpty == false)
    }

    @Test func progressSequenceFromTheChildReachesTheSnapshot() throws {
        // A scripted "shell" emits the sequence itself: typing into the
        // real $SHELL is not CI-safe (a fresh runner's zsh stops at its
        // new-user wizard and never executes the input).
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("crt-progress-probe.sh").path
        try "#!/bin/sh\nprintf '\\033]9;4;1;50\\007'\nsleep 30\n"
            .write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script)
        let session = try TerminalSession(columns: 80, rows: 24, shell: script)
        defer { session.terminate() }
        var progress = session.snapshot.progress
        for _ in 0..<500 where progress == nil {
            usleep(10_000)
            progress = session.snapshot.progress
        }
        #expect(progress == ProgressReport(state: .normal, percent: 50))
    }

    @Test func spawnedShellStartsInTheProfileDirectory() throws {
        let session = try TerminalSession(
            columns: 80, rows: 24, workingDirectory: "/private/tmp")
        defer { session.terminate() }
        // The cwd is set in the child between fork and exec, racing this
        // observer — poll briefly rather than assuming it's visible at once.
        var cwd = SessionInfo.workingDirectory(of: session.shellProcessID)
        for _ in 0..<500 where cwd != "/private/tmp" {
            usleep(10_000)
            cwd = SessionInfo.workingDirectory(of: session.shellProcessID)
        }
        #expect(cwd == "/private/tmp")
    }
}

struct SessionSidebarViewTests {
    @MainActor private func row(
        _ index: Int, active: Bool = false, running: Bool = false
    ) -> SessionRowModel {
        SessionRowModel(
            id: UUID(), index: index, title: "session \(index)",
            metaLine: "~/dev", isActive: active, isRunning: running,
            dirtyCount: nil, theme: SidebarTheme(preset: .museumOff))
    }

    @Test @MainActor func reconcilesRowViewsAgainstModels() {
        let sidebar = SessionSidebarView(theme: SidebarTheme(preset: .museumOff))
        sidebar.update(rows: [row(1, active: true), row(2), row(3)])
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.frameForRow(at: 2) != .zero)

        sidebar.update(rows: [row(1, active: true)])
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.frameForRow(at: 2) == .zero)
        #expect(sidebar.frameForRow(at: 0) != .zero)
    }

    @Test @MainActor func progressBarFollowsTheRowModel() {
        let view = SessionRowView()
        view.frame = NSRect(x: 0, y: 0, width: 224, height: 50)
        var model = row(1)
        view.model = model
        view.layoutSubtreeIfNeeded()
        #expect(view.progressBarFraction == nil)

        model.progress = ProgressReport(state: .normal, percent: 50)
        view.model = model
        view.layoutSubtreeIfNeeded()
        #expect(view.progressBarFraction == 0.5)

        // Indeterminate spans the track (the shimmer carries the meaning).
        model.progress = ProgressReport(state: .indeterminate, percent: 0)
        view.model = model
        view.layoutSubtreeIfNeeded()
        #expect(view.progressBarFraction == 1.0)

        model.progress = nil
        view.model = model
        view.layoutSubtreeIfNeeded()
        #expect(view.progressBarFraction == nil)
    }

    @Test @MainActor func selectionCallbackReportsTheClickedRowIndex() {
        let sidebar = SessionSidebarView(theme: SidebarTheme(preset: .museumOff))
        var selected: Int?
        sidebar.onSelect = { selected = $0 }
        sidebar.update(rows: [row(1, active: true), row(2)])
        // Rows forward clicks by reporting their index.
        sidebar.onSelect?(1)
        #expect(selected == 1)
    }
}

/// Spawns real shells (the test host is the app), so this covers the whole
/// add → select → occlude → close cascade.
struct SessionTabLifecycleTests {
    @Test @MainActor func addSelectAndCloseSessions() {
        let controller = TerminalWindowController(profile: Profile())
        defer { controller.window?.close() }

        #expect(controller.tabs.count == 1)
        controller.addSession()
        #expect(controller.tabs.count == 2)
        #expect(controller.activeTabIndex == 1)
        #expect(controller.tabs[0].container.isHidden)
        #expect(!controller.tabs[1].container.isHidden)

        controller.selectTab(0)
        #expect(controller.activeTabIndex == 0)
        #expect(!controller.tabs[0].container.isHidden)
        #expect(controller.tabs[1].container.isHidden)

        if let pane = controller.tabs[1].panes.first {
            controller.close(pane: pane)
        }
        #expect(controller.tabs.count == 1)
        #expect(controller.activeTabIndex == 0)
    }

    @Test @MainActor func closeSessionClosesTheWholeTab() {
        let controller = TerminalWindowController(profile: Profile())
        defer { controller.window?.close() }
        controller.addSession()
        #expect(controller.tabs.count == 2)

        // The sidebar ✕ closes by row index; the active session shifts.
        controller.closeSession(at: 0)
        #expect(controller.tabs.count == 1)
        #expect(controller.activeTabIndex == 0)
    }

    @Test @MainActor func reorderMovesTheSessionAndFollowsTheActiveOne() {
        let controller = TerminalWindowController(profile: Profile())
        defer { controller.window?.close() }
        controller.addSession()
        controller.addSession()  // 3 tabs, the last one active
        let ids = controller.tabs.map(\.id)

        // Drag the first row into the gap after the last row.
        #expect(controller.reorderSession(id: ids[0], to: 3))
        #expect(controller.tabs.map(\.id) == [ids[1], ids[2], ids[0]])
        // The active session moved indexes but stays active.
        #expect(controller.activeTab?.id == ids[2])
        #expect(controller.activeTabIndex == 1)

        #expect(!controller.reorderSession(id: UUID(), to: 0))
    }

    @Test @MainActor func detachAndAdoptMoveASessionBetweenWindows() {
        let source = TerminalWindowController(profile: Profile())
        let destination = TerminalWindowController(profile: Profile())
        defer {
            source.window?.close()
            destination.window?.close()
        }
        source.addSession()
        let id = source.tabs[0].id

        guard let tab = source.detachSession(id: id) else {
            Issue.record("detach returned nil")
            return
        }
        #expect(source.tabs.count == 1)
        destination.adopt(tab: tab, at: 0)
        #expect(destination.tabs.count == 2)
        #expect(destination.tabs[0].id == id)
        #expect(destination.activeTab?.id == id)
        // The container (and its shells) now live in the new window.
        #expect(tab.container.window === destination.window)
        #expect(!tab.panes.isEmpty)
    }

    @Test @MainActor func detachingTheLastSessionClosesTheWindow() {
        let controller = TerminalWindowController(profile: Profile())
        var closed = false
        controller.onClose = { _ in closed = true }

        let tab = controller.detachSession(id: controller.tabs[0].id)
        #expect(tab != nil)
        #expect(controller.tabs.isEmpty)
        #expect(closed)
        // The detached session survives the window for adoption elsewhere;
        // nobody adopts it here, so clean up its shell.
        for pane in tab?.panes ?? [] {
            pane.session?.terminate()
            pane.renderLoop?.invalidate()
        }
    }

    @Test @MainActor func sidebarMapsDropPointsToGapIndexes() {
        let sidebar = SessionSidebarView(theme: SidebarTheme(preset: .museumOff))
        sidebar.update(rows: [
            SessionRowModel(
                id: UUID(), index: 1, title: "one", metaLine: "~",
                isActive: true, isRunning: false, dirtyCount: nil,
                theme: SidebarTheme(preset: .museumOff)),
            SessionRowModel(
                id: UUID(), index: 2, title: "two", metaLine: "~",
                isActive: false, isRunning: false, dirtyCount: nil,
                theme: SidebarTheme(preset: .museumOff)),
        ])
        sidebar.layoutSubtreeIfNeeded()
        let first = sidebar.frameForRow(at: 0)
        let second = sidebar.frameForRow(at: 1)
        // Top half of a row inserts before it, bottom half after.
        #expect(sidebar.dropGapIndex(at: NSPoint(x: 10, y: first.minY + 4)) == 0)
        #expect(sidebar.dropGapIndex(at: NSPoint(x: 10, y: first.maxY - 4)) == 1)
        #expect(sidebar.dropGapIndex(at: NSPoint(x: 10, y: second.maxY - 4)) == 2)
        // Way below the rows clamps to the end.
        #expect(sidebar.dropGapIndex(at: NSPoint(x: 10, y: second.maxY + 300)) == 2)
    }

    @Test @MainActor func bellInABackgroundSessionBadgesUntilViewed() {
        let controller = TerminalWindowController(profile: Profile())
        defer { controller.window?.close() }
        controller.addSession()  // tab 1 is now active
        let background = controller.tabs[0]

        background.panes.first?.onBell?()
        background.panes.first?.onBell?()
        #expect(background.unseenBells == 2)
        #expect(background.lastBellAt != nil)
        #expect(controller.tabs[1].unseenBells == 0)

        // Viewing the tab consumes the badge.
        controller.selectTab(0)
        #expect(background.unseenBells == 0)
    }

    @Test @MainActor func becomingKeyClearsOnlyTheActiveTabsBadge() {
        let controller = TerminalWindowController(profile: Profile())
        defer { controller.window?.close() }
        controller.addSession()  // tab 1 active
        controller.tabs[0].panes.first?.onBell?()
        // The active tab still badges: the window isn't key in tests, so
        // nobody is watching it.
        controller.tabs[1].panes.first?.onBell?()
        #expect(controller.tabs[0].unseenBells == 1)
        #expect(controller.tabs[1].unseenBells == 1)

        controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(controller.tabs[1].unseenBells == 0)
        #expect(controller.tabs[0].unseenBells == 1)
    }

    @Test @MainActor func dockBadgeSumsAttentionSessionsAcrossWindows() throws {
        let app = try #require(AppDelegate.shared)
        // Registered controllers, like real windows (the dock badge only
        // sums windows the app knows about).
        let first = app.makeWindowController()
        let second = app.makeWindowController()
        defer {
            first.window?.close()
            second.window?.close()
        }

        first.tabs[0].panes.first?.onBell?()
        second.tabs[0].panes.first?.onBell?()
        #expect(NSApp.dockTile.badgeLabel == "2")

        // Viewing each window's session decrements the badge.
        first.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(NSApp.dockTile.badgeLabel == "1")

        second.selectTab(0)
        #expect(NSApp.dockTile.badgeLabel ?? "" == "")
    }

    @Test @MainActor func bellNotificationsDebouncePerSession() {
        let poster = NotificationPoster()
        let noisy = UUID(), other = UUID()
        let start = Date()
        #expect(poster.shouldPostBell(for: noisy, at: start))
        // A burst stays quiet — and does not re-arm the window.
        #expect(!poster.shouldPostBell(for: noisy, at: start.addingTimeInterval(1)))
        #expect(!poster.shouldPostBell(for: noisy, at: start.addingTimeInterval(1.9)))
        // Other sessions debounce independently.
        #expect(poster.shouldPostBell(for: other, at: start.addingTimeInterval(1)))
        // After the window, the next bell posts again.
        #expect(poster.shouldPostBell(for: noisy, at: start.addingTimeInterval(2.5)))
    }

    @Test @MainActor func focusSessionLandsOnTheTabAcrossWindows() throws {
        let app = try #require(AppDelegate.shared)
        let first = app.makeWindowController()
        let second = app.makeWindowController()
        defer {
            first.window?.close()
            second.window?.close()
        }
        second.addSession()  // two tabs; the new one is active
        let target = second.tabs[0].id
        #expect(second.activeTab?.id != target)

        app.focusSession(id: target)
        #expect(second.activeTab?.id == target)
    }

    @Test @MainActor func bellBadgeFollowsTheRowModel() {
        let view = SessionRowView()
        view.frame = NSRect(x: 0, y: 0, width: 220, height: 50)
        var model = SessionRowModel(
            id: UUID(), index: 1, title: "one", metaLine: "~", isActive: false,
            isRunning: false, dirtyCount: nil, theme: SidebarTheme(preset: .museumOff))
        view.model = model
        #expect(!view.showsBellBadge)

        model.attentionCount = 2
        view.model = model
        #expect(view.showsBellBadge)

        model.attentionCount = nil
        view.model = model
        #expect(!view.showsBellBadge)
    }

    @Test @MainActor func presetsApplyPerSessionNotPerWindow() {
        let controller = TerminalWindowController(profile: Profile())
        defer { controller.window?.close() }
        controller.addSession()

        let ibm = CRTPresetLibrary.builtIn.first { $0.name == "IBM 5151" }!
        let before = controller.tabs[0].preset
        controller.apply(preset: ibm)  // active session is tab 1

        #expect(controller.tabs[1].preset == ibm)
        #expect(controller.tabs[1].panes.first?.preset == ibm)
        #expect(controller.tabs[0].preset == before)
        #expect(controller.tabs[0].panes.first?.preset == before)
        #expect(controller.currentPresetName == ibm.name)

        // Chrome follows the active session's theme on switch.
        controller.selectTab(0)
        #expect(controller.currentPresetName == before.name)
    }
}
