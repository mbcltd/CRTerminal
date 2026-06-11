import AppKit
import CRTRendering

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NSWindowController?
    private var session: TerminalSession?
    private var probe: TypistProbe?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()

        let session: TerminalSession
        do {
            session = try TerminalSession(columns: 80, rows: 24)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not start shell"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.session = session
        session.onExit = { _ in
            NSApp.terminate(nil)
        }
        session.onClipboard = { text in
            // OSC 52: applications (tmux, vim) set the system clipboard.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 540))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "CRTerminal"
        window.contentView = view
        view.session = session

        // Renderer exists once the view is in a window; snap to an 80×24 grid.
        let gridSize = view.sizeForGrid(columns: 80, rows: 24)
        window.setContentSize(gridSize)
        if let renderer = view.renderer {
            window.contentResizeIncrements = renderer.cellSize
        }
        window.center()
        window.setFrameAutosaveName("MainWindow")

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        windowController = controller

        NSApp.activate()

        if ProcessInfo.processInfo.environment["CRT_TYPIST"] != nil {
            probe = TypistProbe(view: view, session: session)
            probe?.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.terminate()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About CRTerminal",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide CRTerminal",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit CRTerminal",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(TerminalView.copy(_:)),
            keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(TerminalView.paste(_:)),
            keyEquivalent: "v")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.miniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.zoom(_:)),
            keyEquivalent: "")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}
