import AppKit
import CRTRendering
import TerminalCore

/// One terminal session in a window: its own shell(s) in a tree of split
/// panes, hosted in a container the sidebar shows/hides on selection.
final class SessionTab {
    let id = UUID()
    let container = NSView()
    var panes: [TerminalView] = []
    let createdAt = Date()
    /// Each session wears its own theme; new sessions start from the
    /// profile default.
    var preset: CRTPreset

    init(preset: CRTPreset) {
        self.preset = preset
    }
}

/// One terminal window: a vertical session sidebar (GlassTerm design) on
/// the left, the active session's pane tree on the right, a shared
/// renderer (one glyph atlas per window), and a slide-down search bar.
/// Sessions replaced native window tabs: rows carry live metadata and a
/// hover detail card, which `NSWindow` tabs cannot do.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private(set) var tabs: [SessionTab] = []
    private(set) var activeTabIndex = 0
    private var profile: Profile
    private var sharedRenderer: TerminalRenderer?
    private let rootView = NSView()
    /// The area right of the sidebar; hosts tab containers + search bar.
    private let contentHost = NSView()
    private let sidebar: SessionSidebarView
    private var hoverCard: SessionHoverCard?
    private var hoveredTabID: UUID?
    private var searchBar: SearchBar?
    private var titlebarControls: TitlebarControlCluster?
    /// 1 Hz metadata refresh (titles, running state, cwd, dirty badges).
    private var refreshTimer: Timer?
    /// Latest git dirty counts by tab, filled asynchronously.
    private var dirtyCounts: [UUID: Int] = [:]

    /// Set by the AppDelegate so closed windows are released.
    var onClose: ((TerminalWindowController) -> Void)?

    /// All live panes across every session (probe, teardown, profile apply).
    var panes: [TerminalView] {
        tabs.flatMap { $0.panes }
    }

    var activeTab: SessionTab? {
        tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil
    }

    /// `spawnInitialSession: false` makes an empty shell of a window for
    /// adopting a torn-off session; callers must adopt one immediately.
    init(profile: Profile, spawnInitialSession: Bool = true) {
        self.profile = profile
        sidebar = SessionSidebarView(
            theme: SidebarTheme(preset: profile.preset(in: PresetCatalog.all)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "CRTerminal"
        // Sessions live in the sidebar; native tabbing would duplicate them.
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        rootView.frame = window.contentLayoutRect
        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView

        sidebar.frame = NSRect(
            x: 0, y: 0, width: SessionSidebarView.width, height: rootView.bounds.height)
        sidebar.autoresizingMask = [.height]
        sidebar.onSelect = { [weak self] index in self?.selectTab(index) }
        sidebar.onClose = { [weak self] index in self?.closeSession(at: index) }
        sidebar.onNewSession = { [weak self] in self?.addSession() }
        sidebar.onHover = { [weak self] index, rowFrame in
            self?.hoverChanged(index: index, rowFrame: rowFrame)
        }
        sidebar.onDropSession = { [weak self] id, gapIndex in
            guard let self else { return false }
            // The app delegate resolves drags that came from another
            // window; outside it (unit tests) reorder locally.
            if let app = AppDelegate.shared,
               app.moveSession(id: id, to: self, at: gapIndex) {
                return true
            }
            return self.reorderSession(id: id, to: gapIndex)
        }
        sidebar.onDragEndedWithoutDrop = { id, screenPoint in
            AppDelegate.shared?.sessionDragEnded(id: id, droppedAt: screenPoint)
        }
        rootView.addSubview(sidebar)

        contentHost.frame = NSRect(
            x: SessionSidebarView.width, y: 0,
            width: rootView.bounds.width - SessionSidebarView.width,
            height: rootView.bounds.height)
        contentHost.autoresizingMask = [.width, .height]
        rootView.addSubview(contentHost)

        addTitlebarControls(to: window)

        if spawnInitialSession {
            addSession()
            sizeWindowToGrid(columns: 80, rows: 24)
        }
        window.center()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSessionMetadata() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalWindowController is created in code")
    }

    var focusedPane: TerminalView? {
        window?.firstResponder as? TerminalView ?? activeTab?.panes.first
    }

    // MARK: Renderer (shared across the window's panes)

    private func rendererForPane() -> TerminalRenderer? {
        if let sharedRenderer { return sharedRenderer }
        let renderer = TerminalRenderer(
            font: profile.font, scale: window?.backingScaleFactor ?? 2)
        sharedRenderer = renderer
        return renderer
    }

    /// The profile's preset: the default new sessions start from.
    private func currentPreset() -> CRTPreset {
        profile.preset(in: PresetCatalog.all)
    }

    /// The active session's preset: what the window chrome reflects.
    var activePreset: CRTPreset {
        activeTab?.preset ?? currentPreset()
    }

    // MARK: Sessions (sidebar tabs)

    /// Spawns a fresh shell in a new sidebar session and selects it.
    @objc func newSession(_ sender: Any?) {
        addSession()
    }

    func addSession() {
        let tab = SessionTab(preset: currentPreset())
        guard let pane = makePane(in: tab) else { return }
        tab.container.frame = contentHost.bounds
        tab.container.autoresizingMask = [.width, .height]
        contentHost.addSubview(tab.container)
        tabs.append(tab)
        install(pane, in: tab.container)
        selectTab(tabs.count - 1)
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabIndex = index
        for (i, tab) in tabs.enumerated() {
            let active = i == index
            tab.container.isHidden = !active
            for pane in tab.panes {
                pane.setOccluded(!active)
            }
        }
        if let pane = activeTab?.panes.first {
            window?.makeFirstResponder(pane)
        }
        hideHoverCard()
        applyChrome(preset: activePreset)
        refreshSessionMetadata()
    }

    @objc func nextSession(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        selectTab((activeTabIndex + 1) % tabs.count)
    }

    @objc func previousSession(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        selectTab((activeTabIndex + tabs.count - 1) % tabs.count)
    }

    // MARK: Panes

    private func makePane(in tab: SessionTab) -> TerminalView? {
        let session: TerminalSession
        do {
            session = try TerminalSession(
                columns: 80, rows: 24,
                shell: profile.shellPath,
                workingDirectory: profile.resolvedWorkingDirectory,
                scrollbackLines: profile.scrollbackLines)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not start shell"
            alert.informativeText = String(describing: error)
            alert.runModal()
            return nil
        }
        let pane = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        pane.preset = tab.preset
        pane.session = session
        session.onClipboard = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        wire(pane: pane)
        tab.panes.append(pane)
        return pane
    }

    /// Points a pane's renderer and session callbacks at this window; runs
    /// on creation and again when a dragged session is adopted from
    /// another window.
    private func wire(pane: TerminalView) {
        pane.rendererProvider = { [weak self] in self?.rendererForPane() }
        guard let session = pane.session else { return }
        session.onExit = { [weak self, weak pane] _ in
            guard let pane else { return }
            self?.close(pane: pane)
        }
        session.onNotification = { [weak self] notification in
            NotificationPoster.shared.post(
                notification, windowIsKey: self?.window?.isKeyWindow ?? false)
        }
    }

    private func install(_ pane: TerminalView, in container: NSView) {
        pane.frame = container.bounds
        pane.autoresizingMask = [.width, .height]
        container.addSubview(pane)
        window?.makeFirstResponder(pane)
    }

    func sizeWindowToGrid(columns: Int, rows: Int) {
        guard let window, let pane = activeTab?.panes.first else { return }
        let size = pane.sizeForGrid(columns: columns, rows: rows)
        window.setContentSize(NSSize(
            width: size.width + SessionSidebarView.width, height: size.height))
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
              let tab = tab(owning: existing),
              let newPane = makePane(in: tab) else { return }

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

    private func tab(owning pane: TerminalView) -> SessionTab? {
        tabs.first { $0.panes.contains { $0 === pane } }
    }

    /// Closes a pane; the last pane closing closes the session, the last
    /// session closing closes the window.
    func close(pane: TerminalView) {
        pane.session?.terminate()
        pane.renderLoop?.invalidate()
        guard let tab = tab(owning: pane),
              let tabIndex = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.panes.removeAll { $0 === pane }

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

        if tab.panes.isEmpty {
            tab.container.removeFromSuperview()
            tabs.remove(at: tabIndex)
            dirtyCounts[tab.id] = nil
            guard !tabs.isEmpty else {
                window?.close()
                return
            }
            if tabIndex < activeTabIndex {
                activeTabIndex -= 1
            }
            selectTab(min(activeTabIndex, tabs.count - 1))
        } else if tabIndex == activeTabIndex, let next = tab.panes.first {
            window?.makeFirstResponder(next)
        }
        refreshSessionMetadata()
    }

    /// Closes a whole sidebar session — every pane in it (the row's ✕).
    func closeSession(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        for pane in tabs[index].panes {
            close(pane: pane)
        }
    }

    // MARK: Session dragging (reorder / move between windows)

    /// Sidebar drag-reorder: moves the session into the gap index the drop
    /// indicator showed (0...count, between rows after removal).
    @discardableResult
    func reorderSession(id: UUID, to gapIndex: Int) -> Bool {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return false }
        var to = min(max(0, gapIndex), tabs.count)
        if from < to { to -= 1 }
        let active = activeTab
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        if let active, let index = tabs.firstIndex(where: { $0 === active }) {
            activeTabIndex = index
        }
        refreshSessionMetadata()
        return true
    }

    /// Removes a session from this window without terminating its shells,
    /// for adoption by another window. A window left with no sessions
    /// closes — so callers must attach the tab to an already-open window.
    func detachSession(id: UUID) -> SessionTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        dirtyCounts[tab.id] = nil
        tab.container.removeFromSuperview()
        hideHoverCard()
        guard !tabs.isEmpty else {
            window?.close()
            return tab
        }
        if index < activeTabIndex {
            activeTabIndex -= 1
        }
        selectTab(min(activeTabIndex, tabs.count - 1))
        return tab
    }

    /// Adopts a session detached from another window: the tab keeps its
    /// shells and theme, but its panes join this window's renderer (one
    /// glyph atlas per window) and callbacks.
    func adopt(tab: SessionTab, at gapIndex: Int) {
        let index = min(max(0, gapIndex), tabs.count)
        tab.container.frame = contentHost.bounds
        tab.container.autoresizingMask = [.width, .height]
        contentHost.addSubview(tab.container)
        tabs.insert(tab, at: index)
        for pane in tab.panes {
            wire(pane: pane)
            pane.resetRenderer()
        }
        selectTab(index)
    }

    /// ⌘W: close the focused pane (the window when it's the only one).
    @objc func closePane(_ sender: Any?) {
        guard let pane = focusedPane else {
            window?.close()
            return
        }
        close(pane: pane)
    }

    // MARK: Sidebar metadata

    /// Cheap kernel probes each tick; git runs async behind a short cache.
    private func refreshSessionMetadata() {
        var rows: [SessionRowModel] = []
        for (index, tab) in tabs.enumerated() {
            guard let session = tab.panes.first?.session else { continue }
            let shellPID = session.shellProcessID
            let foreground = session.foregroundProcessGroup
            let isRunning = foreground > 0 && foreground != shellPID
            let shellName = SessionInfo.processName(of: shellPID)
                ?? (profile.shellPath as NSString?)?.lastPathComponent ?? "shell"
            let title = session.snapshot.title ?? shellName
            let cwd = SessionInfo.workingDirectory(of: isRunning ? foreground : shellPID)
                ?? SessionInfo.workingDirectory(of: shellPID)
            let metaLine: String
            if isRunning {
                let name = SessionInfo.processName(of: foreground) ?? "…"
                metaLine = "\(name) · live"
            } else {
                metaLine = cwd.map(SessionInfo.displayName(path:)) ?? shellName
            }
            rows.append(SessionRowModel(
                id: tab.id, index: index + 1, title: title, metaLine: metaLine,
                isActive: index == activeTabIndex, isRunning: isRunning,
                dirtyCount: dirtyCounts[tab.id],
                theme: SidebarTheme(preset: tab.preset)))
            if let cwd {
                let tabID = tab.id
                SessionInfo.gitStatus(in: cwd) { [weak self] status in
                    guard let self else { return }
                    let newCount = status.map(\.dirtyCount)
                    if self.dirtyCounts[tabID] != newCount {
                        self.dirtyCounts[tabID] = newCount
                        // Re-derive rows; the git result is now cached.
                        self.refreshSessionMetadata()
                    }
                }
            }
        }
        sidebar.update(rows: rows)
        if let active = rows.first(where: { $0.isActive }) {
            window?.title = active.title
        }
    }

    // MARK: Hover card

    private func hoverChanged(index: Int?, rowFrame: NSRect) {
        guard let index, tabs.indices.contains(index) else {
            hideHoverCard()
            return
        }
        let tab = tabs[index]
        hoveredTabID = tab.id
        guard let session = tab.panes.first?.session else { return }

        let theme = SidebarTheme(preset: tab.preset)
        let shellPID = session.shellProcessID
        let foreground = session.foregroundProcessGroup
        let isRunning = foreground > 0 && foreground != shellPID
        let shellName = SessionInfo.processName(of: shellPID) ?? "shell"
        let cwd = SessionInfo.workingDirectory(of: isRunning ? foreground : shellPID)
            ?? SessionInfo.workingDirectory(of: shellPID)
        let uptime = Self.format(uptime: Date().timeIntervalSince(tab.createdAt))
        let lastExit = session.snapshot.promptMarks.last(where: { $0.exitCode != nil })?
            .exitCode
        var model = SessionCardModel(
            title: session.snapshot.title ?? shellName,
            index: index + 1,
            isRunning: isRunning,
            statusText: isRunning ? "running" : "idle",
            path: cwd.map(SessionInfo.abbreviate(path:)) ?? "—",
            branchLine: cwd == nil ? "" : nil,
            branchIsDirty: false,
            statusLine: (isRunning ? "● running · up " : "idle · up ") + uptime,
            processLine: isRunning
                ? "\(SessionInfo.processName(of: foreground) ?? "…") · pid \(foreground)"
                : "\(shellName) · pid \(shellPID)",
            exitLine: lastExit.map { $0 == 0 ? "✓ 0" : "✗ \($0)" })

        let card = hoverCard ?? {
            let card = SessionHoverCard(theme: theme)
            rootView.addSubview(card)
            hoverCard = card
            return card
        }()
        let height = card.update(model: model, theme: theme)
        let rowInRoot = sidebar.convert(rowFrame, to: rootView)
        let y = min(
            max(8, rowInRoot.maxY + 8 - height),
            rootView.bounds.height - height - 8)
        card.frame = NSRect(
            x: SessionSidebarView.width + 12, y: y,
            width: SessionHoverCard.width, height: height)
        card.isHidden = false

        // Git arrives async; only apply if the cursor is still on this row.
        if let cwd {
            let tabID = tab.id
            SessionInfo.gitStatus(in: cwd) { [weak self] status in
                guard let self, self.hoveredTabID == tabID,
                      let card = self.hoverCard, !card.isHidden else { return }
                if let status {
                    model.branchLine = "⎇ \(status.branch) · "
                        + (status.dirtyCount > 0
                            ? "✗ \(status.dirtyCount) changed" : "✓ clean")
                    model.branchIsDirty = status.dirtyCount > 0
                } else {
                    model.branchLine = ""
                }
                _ = card.update(model: model, theme: theme)
            }
        }
    }

    private func hideHoverCard() {
        hoveredTabID = nil
        hoverCard?.isHidden = true
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
        guard window != nil else { return }
        let height: CGFloat = 32
        bar.frame = NSRect(
            x: 0, y: contentHost.bounds.height - height,
            width: contentHost.bounds.width, height: height)
        bar.autoresizingMask = [.width, .minYMargin]
        contentHost.addSubview(bar)
        searchBar = bar
        bar.focus()
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

    /// Re-applies an edited profile. A font change rebuilds the window's
    /// shared renderer. The profile's preset is only the default for new
    /// sessions — existing sessions keep the theme they're wearing.
    func apply(profile: Profile) {
        let fontChanged = profile.font != self.profile.font
        self.profile = profile
        if fontChanged {
            sharedRenderer = nil
            for pane in panes {
                pane.resetRenderer()
            }
        }
        applyChrome(preset: activePreset)
    }

    /// Themes the active session only; other sessions keep theirs.
    func apply(preset: CRTPreset) {
        guard let tab = activeTab else { return }
        tab.preset = preset
        for pane in tab.panes {
            pane.preset = preset
        }
        applyChrome(preset: preset)
        refreshSessionMetadata()
    }

    /// Window chrome (titlebar cluster, sidebar rail) wears the active
    /// session's theme.
    private func applyChrome(preset: CRTPreset) {
        titlebarControls?.update(preset: preset)
        sidebar.apply(theme: SidebarTheme(preset: preset))
        hideHoverCard()
    }

    var currentPresetName: String {
        activePreset.name
    }

    // MARK: Window plumbing

    /// The GlassTerm-design control cluster: theme switcher + a degauss
    /// button that only exists while the active preset is a CRT.
    private func addTitlebarControls(to window: NSWindow) {
        let cluster = TitlebarControlCluster(
            presets: PresetCatalog.all, currentPreset: currentPreset())
        cluster.onSelectPreset = { [weak self] preset in
            self?.apply(preset: preset)
            // Remember the choice in the default profile; the store change
            // fans out to every other open window.
            var profile = ProfileStore.shared.defaultProfile
            profile.presetName = preset.name
            ProfileStore.shared.update(profile)
        }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = cluster
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        titlebarControls = cluster
    }

    private static func format(uptime: TimeInterval) -> String {
        let minutes = Int(uptime) / 60
        if minutes < 1 { return "\(Int(uptime))s" }
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        for pane in panes {
            pane.session?.terminate()
            pane.renderLoop?.invalidate()
        }
        tabs.removeAll()
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
