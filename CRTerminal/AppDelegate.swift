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
        NSApp.mainMenu = makeMainMenu()
        ProfileStore.shared.onChange = { [weak self] in
            self?.profilesChanged()
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

    func makeWindowController() -> TerminalWindowController {
        let controller = TerminalWindowController(
            profile: ProfileStore.shared.defaultProfile)
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)
        return controller
    }

    private var keyController: TerminalWindowController? {
        NSApp.keyWindow?.windowController as? TerminalWindowController
            ?? controllers.last
    }

    @objc private func newWindow(_ sender: Any?) {
        makeWindowController().showWindow(sender)
    }

    @objc private func newTab(_ sender: Any?) {
        if let key = keyController {
            key.newWindowForTab(sender)
        } else {
            newWindow(sender)
        }
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
        let newTabItem = shellMenu.addItem(
            withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        newTabItem.target = self
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
            let item = viewMenu.addItem(
                withTitle: preset.name,
                action: #selector(selectPreset(_:)),
                keyEquivalent: index < 9 ? String(index + 1) : "")
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
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}
