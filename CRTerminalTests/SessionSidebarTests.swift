import AppKit
import CRTRendering
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

struct SessionInfoTests {
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
