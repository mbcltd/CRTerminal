import AppKit
import CRTRendering
import TerminalCore

/// One terminal window: a tree of split panes (nested NSSplitViews), a
/// shared renderer (one glyph atlas per window), a slide-down search bar,
/// and native tabbing. New tabs are just new windows in the tab group.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private(set) var panes: [TerminalView] = []
    private var profile: Profile
    private var sharedRenderer: TerminalRenderer?
    private let paneContainer = NSView()
    private var searchBar: SearchBar?

    /// Set by the AppDelegate so closed windows are released.
    var onClose: ((TerminalWindowController) -> Void)?

    init(profile: Profile) {
        self.profile = profile
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "CRTerminal"
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self

        paneContainer.frame = window.contentLayoutRect
        paneContainer.autoresizingMask = [.width, .height]
        window.contentView = paneContainer

        addDegaussButton(to: window)

        guard let firstPane = makePane() else { return }
        install(firstPane, in: paneContainer)
        sizeWindowToGrid(columns: 80, rows: 24)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalWindowController is created in code")
    }

    var focusedPane: TerminalView? {
        window?.firstResponder as? TerminalView ?? panes.first
    }

    // MARK: Renderer (shared across the window's panes)

    private func rendererForPane() -> TerminalRenderer? {
        if let sharedRenderer { return sharedRenderer }
        let renderer = TerminalRenderer(
            font: profile.font, scale: window?.backingScaleFactor ?? 2)
        renderer?.preset = currentPreset()
        sharedRenderer = renderer
        return renderer
    }

    private func currentPreset() -> CRTPreset {
        profile.preset(in: PresetCatalog.all)
    }

    // MARK: Panes

    private func makePane() -> TerminalView? {
        let session: TerminalSession
        do {
            session = try TerminalSession(
                columns: 80, rows: 24,
                shell: profile.shellPath,
                scrollbackLines: profile.scrollbackLines)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not start shell"
            alert.informativeText = String(describing: error)
            alert.runModal()
            return nil
        }
        let pane = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        pane.rendererProvider = { [weak self] in self?.rendererForPane() }
        pane.preset = currentPreset()
        pane.session = session
        session.onExit = { [weak self, weak pane] _ in
            guard let pane else { return }
            self?.close(pane: pane)
        }
        session.onClipboard = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        session.onNotification = { [weak self] notification in
            NotificationPoster.shared.post(
                notification, windowIsKey: self?.window?.isKeyWindow ?? false)
        }
        panes.append(pane)
        return pane
    }

    private func install(_ pane: TerminalView, in container: NSView) {
        pane.frame = container.bounds
        pane.autoresizingMask = [.width, .height]
        container.addSubview(pane)
        window?.makeFirstResponder(pane)
    }

    func sizeWindowToGrid(columns: Int, rows: Int) {
        guard let window, let pane = panes.first else { return }
        let size = pane.sizeForGrid(columns: columns, rows: rows)
        window.setContentSize(size)
        if let renderer = pane.renderer {
            window.contentResizeIncrements = renderer.cellSize
        }
    }

    // MARK: Splits

    /// Replaces the focused pane with a split view holding it + a new pane.
    @objc func splitRight(_ sender: Any?) {
        split(vertical: true)
    }

    @objc func splitDown(_ sender: Any?) {
        split(vertical: false)
    }

    private func split(vertical: Bool) {
        guard let existing = focusedPane,
              let host = existing.superview,
              let newPane = makePane() else { return }

        let splitView = NSSplitView(frame: existing.frame)
        splitView.isVertical = vertical
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]

        if let parentSplit = host as? NSSplitView {
            let index = parentSplit.arrangedSubviews.firstIndex(of: existing) ?? 0
            existing.removeFromSuperview()
            parentSplit.insertArrangedSubview(splitView, at: index)
        } else {
            existing.removeFromSuperview()
            host.addSubview(splitView)
        }
        existing.autoresizingMask = [.width, .height]
        newPane.autoresizingMask = [.width, .height]
        splitView.addArrangedSubview(existing)
        splitView.addArrangedSubview(newPane)
        splitView.adjustSubviews()
        window?.makeFirstResponder(newPane)
    }

    /// Closes a pane; the last pane closing closes the window.
    func close(pane: TerminalView) {
        pane.session?.terminate()
        pane.renderLoop?.invalidate()
        panes.removeAll { $0 === pane }
        guard !panes.isEmpty else {
            window?.close()
            return
        }
        if let splitView = pane.superview as? NSSplitView {
            pane.removeFromSuperview()
            // A split with one child left unwraps back into its parent.
            if splitView.arrangedSubviews.count == 1,
               let survivor = splitView.arrangedSubviews.first {
                survivor.removeFromSuperview()
                if let parentSplit = splitView.superview as? NSSplitView {
                    let index = parentSplit.arrangedSubviews.firstIndex(of: splitView) ?? 0
                    splitView.removeFromSuperview()
                    survivor.autoresizingMask = [.width, .height]
                    parentSplit.insertArrangedSubview(survivor, at: index)
                } else if let host = splitView.superview {
                    survivor.frame = host.bounds
                    survivor.autoresizingMask = [.width, .height]
                    splitView.removeFromSuperview()
                    host.addSubview(survivor)
                }
            }
        } else {
            pane.removeFromSuperview()
        }
        if let next = panes.first {
            window?.makeFirstResponder(next)
        }
    }

    /// ⌘W: close the focused pane (the window when it's the only one).
    @objc func closePane(_ sender: Any?) {
        guard let pane = focusedPane else {
            window?.close()
            return
        }
        close(pane: pane)
    }

    // MARK: Tabs

    /// The titlebar plus button and File ▸ New Tab land here.
    override func newWindowForTab(_ sender: Any?) {
        guard let window,
              let controller = AppDelegate.shared?.makeWindowController() else { return }
        if let newWindow = controller.window {
            window.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(sender)
        }
    }

    // MARK: Search

    override func performTextFinderAction(_ sender: Any?) {
        toggleSearch(sender)
    }

    @objc func toggleSearch(_ sender: Any?) {
        if let searchBar {
            searchBar.focus()
            return
        }
        let bar = SearchBar(frame: .zero)
        bar.onSearch = { [weak self] query, backward in
            self?.focusedPane?.find(query, backward: backward)
        }
        bar.onDismiss = { [weak self] in
            self?.dismissSearch()
        }
        guard let window else { return }
        let height: CGFloat = 32
        bar.frame = NSRect(
            x: 0, y: paneContainer.bounds.height - height,
            width: paneContainer.bounds.width, height: height)
        bar.autoresizingMask = [.width, .minYMargin]
        paneContainer.addSubview(bar)
        searchBar = bar
        bar.focus()
        _ = window
    }

    @objc func findNext(_ sender: Any?) {
        searchBar?.repeatSearch(backward: false)
    }

    @objc func findPrevious(_ sender: Any?) {
        searchBar?.repeatSearch(backward: true)
    }

    private func dismissSearch() {
        searchBar?.removeFromSuperview()
        searchBar = nil
        for pane in panes {
            pane.endSearch()
        }
        if let pane = focusedPane {
            window?.makeFirstResponder(pane)
        }
    }

    // MARK: Profile

    /// Re-applies an edited profile. Preset and scrollback apply live;
    /// a font change rebuilds the window's shared renderer.
    func apply(profile: Profile) {
        let fontChanged = profile.font != self.profile.font
        self.profile = profile
        let preset = currentPreset()
        if fontChanged {
            sharedRenderer = nil
            for pane in panes {
                pane.resetRenderer()
            }
        }
        sharedRenderer?.preset = preset
        for pane in panes {
            pane.preset = preset
        }
    }

    func apply(preset: CRTPreset) {
        profile.presetName = preset.name
        for pane in panes {
            pane.preset = preset
        }
    }

    var currentPresetName: String {
        profile.presetName
    }

    // MARK: Window plumbing

    private func addDegaussButton(to window: NSWindow) {
        let button = NSButton(
            title: "Degauss", target: nil, action: #selector(TerminalView.degauss(_:)))
        button.bezelStyle = .accessoryBarAction
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let size = button.fittingSize
        button.frame = NSRect(x: 0, y: 2, width: size.width, height: size.height)
        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: size.width + 8, height: size.height + 4))
        container.addSubview(button)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
    }

    func windowWillClose(_ notification: Notification) {
        for pane in panes {
            pane.session?.terminate()
            pane.renderLoop?.invalidate()
        }
        panes.removeAll()
        onClose?(self)
    }
}

/// The slide-down find bar: a search field plus prev/next, Esc dismisses.
final class SearchBar: NSVisualEffectView, NSSearchFieldDelegate {
    private let field = NSSearchField()
    var onSearch: ((String, Bool) -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .headerView
        blendingMode = .withinWindow

        field.placeholderString = "Search scrollback"
        field.delegate = self
        field.target = self
        field.action = #selector(searchSubmitted(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        let previous = NSButton(
            image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous match")!,
            target: self, action: #selector(findPrevious(_:)))
        let next = NSButton(
            image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next match")!,
            target: self, action: #selector(findNext(_:)))
        let done = NSButton(title: "Done", target: self, action: #selector(dismiss(_:)))
        for button in [previous, next, done] {
            button.bezelStyle = .accessoryBarAction
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            previous.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            previous.centerYAnchor.constraint(equalTo: centerYAnchor),
            next.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 4),
            next.centerYAnchor.constraint(equalTo: centerYAnchor),
            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            done.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SearchBar is created in code")
    }

    func focus() {
        window?.makeFirstResponder(field)
    }

    func repeatSearch(backward: Bool) {
        guard !field.stringValue.isEmpty else { return }
        onSearch?(field.stringValue, backward)
    }

    @objc private func searchSubmitted(_ sender: Any?) {
        repeatSearch(backward: true)
    }

    @objc private func findNext(_ sender: Any?) {
        repeatSearch(backward: false)
    }

    @objc private func findPrevious(_ sender: Any?) {
        repeatSearch(backward: true)
    }

    @objc private func dismiss(_ sender: Any?) {
        onDismiss?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onDismiss?()
            return true
        }
        return false
    }
}
