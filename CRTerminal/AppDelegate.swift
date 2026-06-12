import AppKit
import CRTRendering
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) static var shared: AppDelegate?

    private var controllers: [TerminalWindowController] = []
    private var settingsWindow: NSWindow?
    private var previewRenderer: PresetPreviewRenderer?
    private var probe: TypistProbe?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any Profile.font resolution: nil fontName means Geist Mono.
        BundledFonts.register()
        NSApp.mainMenu = makeMainMenu()
        NotificationPoster.shared.activate()
        ProfileStore.shared.onChange = { [weak self] in
            self?.profilesChanged()
        }
        AlertSettings.shared.onChange = { [weak self] in
            guard let self else { return }
            for controller in self.controllers {
                controller.refreshSessionMetadata()
            }
            self.refreshDockBadge()
        }

        let controller = makeWindowController()
        controller.window?.setFrameAutosaveName("MainWindow")
        controller.showWindow(nil)
        NSApp.activate()

        if ProcessInfo.processInfo.environment["CRT_TYPIST"] != nil,
           let pane = controller.panes.first, let session = pane.session {
            probe = TypistProbe(view: pane, session: session)
            probe?.start()
        }
        if ProcessInfo.processInfo.environment["CRT_JUMP_PROBE"] != nil {
            runJumpProbe(controller: controller)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in controllers {
            for pane in controller.panes {
                pane.session?.terminate()
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Windows & tabs

    func makeWindowController(spawnInitialSession: Bool = true) -> TerminalWindowController {
        let controller = TerminalWindowController(
            profile: ProfileStore.shared.defaultProfile,
            spawnInitialSession: spawnInitialSession)
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
            self?.refreshDockBadge()
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

    private var jumpMenu: JumpMenuController?

    /// ⌘K toggles a palette searching every session in every window.
    @objc private func showJumpMenu(_ sender: Any?) {
        if let jumpMenu {
            jumpMenu.dismiss()
            return
        }
        let targets = JumpTargetBuilder.targets(across: controllers)
        guard !targets.isEmpty else { return }
        let theme = SidebarTheme(
            preset: keyController?.activePreset
                ?? ProfileStore.shared.defaultProfile.preset(in: PresetCatalog.all))
        let menu = JumpMenuController(targets: targets, theme: theme) { [weak self] target in
            self?.jump(to: target)
        }
        menu.onDismiss = { [weak self] in self?.jumpMenu = nil }
        jumpMenu = menu
        menu.show(over: NSApp.keyWindow)
    }

    private func jump(to target: JumpTarget) {
        focusSession(id: target.tabID)
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

    private func profilesChanged() {
        let profile = ProfileStore.shared.defaultProfile
        for controller in controllers {
            controller.apply(profile: profile)
        }
    }

    // MARK: CRT presets

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let preset = PresetCatalog.all.first(where: { $0.name == name })
        else { return }
        keyController?.apply(preset: preset)
        // Remember the choice in the default profile.
        var profile = ProfileStore.shared.defaultProfile
        profile.presetName = preset.name
        ProfileStore.shared.update(profile)
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectPreset(_:)) {
            let current = keyController?.currentPresetName
                ?? ProfileStore.shared.defaultProfile.presetName
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
        appMenu.addItem(
            withTitle: "About CRTerminal",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(
            withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide CRTerminal",
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
            withTitle: "Quit CRTerminal",
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
        let gallery = viewMenu.addItem(
            withTitle: "Preset Gallery…", action: #selector(showSettings(_:)), keyEquivalent: "p")
        gallery.keyEquivalentModifierMask = [.command, .shift]
        gallery.target = self
        viewMenu.addItem(.separator())
        let degauss = viewMenu.addItem(
            withTitle: "Degauss",
            action: #selector(TerminalView.degauss(_:)), keyEquivalent: "d")
        degauss.keyEquivalentModifierMask = [.command, .option]
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
