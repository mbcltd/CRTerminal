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
    /// global settings default.
    var preset: CRTPreset
    /// User-chosen name that overrides the inferred one (process/OSC title).
    /// `nil` (or empty) means fall back to the automatic name.
    var customName: String?
    /// Bells (and notifications) that arrived while the session wasn't
    /// being watched; the sidebar badges the row until the tab is viewed.
    var unseenBells = 0
    var lastBellAt: Date?

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
    private var settings: TerminalSettings
    /// One renderer (and glyph atlas) per distinct face + scale. Panes
    /// with the same preset font and `fontSizeScale` share an atlas; a
    /// preset like the Commodore 1702 (1.5× in the C64 face) gets its own
    /// alongside the default sessions in the same window.
    private struct FontKey: Hashable {
        let name: String
        let scale: Double
    }
    private var sharedRenderers: [FontKey: TerminalRenderer] = [:]
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
    /// Fired when the layout changes in a way worth persisting (sessions
    /// added/closed/split/reordered, active tab switched). The AppDelegate
    /// debounces these into a coalesced restoration save (R3).
    var onSignificantChange: (() -> Void)?

    private func noteSignificantChange() {
        onSignificantChange?()
    }

    /// All live panes across every session (probe, teardown, settings apply).
    var panes: [TerminalView] {
        tabs.flatMap { $0.panes }
    }

    var activeTab: SessionTab? {
        tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil
    }

    /// `spawnInitialSession: false` makes an empty shell of a window for
    /// adopting a torn-off session; callers must adopt one immediately.
    init(settings: TerminalSettings, spawnInitialSession: Bool = true,
         initialWorkingDirectory: String? = nil) {
        self.settings = settings
        self.initialWorkingDirectory = initialWorkingDirectory
        sidebar = SessionSidebarView(
            theme: SidebarTheme(preset: settings.preset(in: PresetCatalog.all)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "crterm"
        // Sessions live in the sidebar; native tabbing would duplicate them.
        window.tabbingMode = .disallowed
        // Session restoration is driven entirely from our own on-disk layout +
        // content files (see `AppDelegate.restoreLayoutFromDisk`), not AppKit's
        // window restoration — the latter only fires when the system "Close
        // windows when quitting" preference allows it, which made restore feel
        // unreliable. `isRestorable = false` keeps AppKit from encoding a
        // parallel (and divergent) copy of the layout. The `restorationClass`
        // is kept only so any *stale* saved state from older builds resolves to
        // `WindowRestoration`, which now no-ops rather than reviving a window.
        window.identifier = NSUserInterfaceItemIdentifier(UUID().uuidString)
        window.restorationClass = WindowRestoration.self
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        rootView.frame = window.contentLayoutRect
        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView

        sidebar.frame = NSRect(
            x: 0, y: 0, width: SessionSidebarView.width, height: rootView.bounds.height)
        sidebar.autoresizingMask = [.height]
        // Hidden until a second session exists; `updateSidebarVisibility`
        // reveals it and reclaims the content inset then.
        sidebar.isHidden = true
        sidebar.onSelect = { [weak self] index in self?.selectTab(index) }
        sidebar.onClose = { [weak self] index in self?.closeSession(at: index) }
        sidebar.onRename = { [weak self] id, name in self?.renameSession(id: id, to: name) }
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

        // Full width to start: the lone startup session has no sidebar.
        contentHost.frame = rootView.bounds
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

    /// The working directory of the focused pane's session, so new tabs and
    /// splits open where the user is currently working. Prefers the shell's
    /// live OSC 7 report (survives a cd since the last probe); falls back to
    /// the kernel query.
    var focusedWorkingDirectory: String? {
        guard let session = focusedPane?.session else { return nil }
        return session.snapshot.currentDirectory
            ?? SessionInfo.workingDirectory(of: session.shellProcessID)
    }

    /// Seed cwd for this window's *first* session, so ⌘N opens where the
    /// previously focused window was working (new tab/split already inherit
    /// via `focusedWorkingDirectory`). Consumed once, then cleared — later
    /// sessions inherit from their own focused pane.
    private var initialWorkingDirectory: String?

    private func consumeInitialWorkingDirectory() -> String? {
        defer { initialWorkingDirectory = nil }
        return initialWorkingDirectory
    }

    // MARK: Renderer (shared across the window's panes)

    private func rendererForPane(name: String, scale: Double) -> TerminalRenderer? {
        let key = FontKey(name: name, scale: scale)
        if let existing = sharedRenderers[key] { return existing }
        let renderer = TerminalRenderer(
            font: settings.font(name: name, scale: scale),
            scale: window?.backingScaleFactor ?? 2)
        renderer?.setLigatures(settings.ligatures)
        sharedRenderers[key] = renderer
        return renderer
    }

    /// The settings preset: the default new sessions start from.
    private func currentPreset() -> CRTPreset {
        settings.preset(in: PresetCatalog.all)
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

    /// Spawns a session, optionally seeding it from a restored snapshot
    /// (session restoration R1): the saved grid/scrollback repaint as static
    /// text and a fresh shell runs below them, in the snapshot's cwd.
    @discardableResult
    func addSession(restoringFrom snapshot: TerminalStateSnapshot? = nil) -> SessionTab? {
        let tab = SessionTab(preset: currentPreset())
        guard let pane = makePane(in: tab, restoringFrom: snapshot) else { return nil }
        tab.container.frame = contentHost.bounds
        tab.container.autoresizingMask = [.width, .height]
        contentHost.addSubview(tab.container)
        tabs.append(tab)
        install(pane, in: tab.container)
        selectTab(tabs.count - 1)
        noteSignificantChange()
        return tab
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
        activeTab?.unseenBells = 0
        hideHoverCard()
        updateSidebarVisibility()
        applyChrome(preset: activePreset)
        refreshSessionMetadata()
        sidebar.scrollRowIntoView(at: index)
        noteSignificantChange()
    }

    /// The session sidebar only earns its space once there's a choice to
    /// make: a lone session uses the full window width and the pane tree
    /// reflows to fill whatever the sidebar leaves behind. Called from
    /// `selectTab`, the chokepoint every session add/close/move passes
    /// through.
    private func updateSidebarVisibility() {
        let showSidebar = tabs.count > 1
        guard sidebar.isHidden == showSidebar else { return }
        sidebar.isHidden = !showSidebar
        let inset = showSidebar ? SessionSidebarView.width : 0
        contentHost.frame = NSRect(
            x: inset, y: 0,
            width: rootView.bounds.width - inset,
            height: rootView.bounds.height)
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

    private func makePane(
        in tab: SessionTab, restoringFrom snapshot: TerminalStateSnapshot? = nil,
        sessionID: UUID? = nil
    ) -> TerminalView? {
        let session: TerminalSession
        do {
            session = try TerminalSession(
                columns: 80, rows: 24,
                shell: settings.shellPath,
                // Restore in the saved directory; otherwise inherit the
                // focused pane's cwd (new tab/split opens where you are), or
                // the seed cwd handed to a fresh ⌘N window; fall back to the
                // setting.
                workingDirectory: snapshot?.workingDirectoryHint
                    ?? focusedWorkingDirectory
                    ?? consumeInitialWorkingDirectory()
                    ?? settings.resolvedWorkingDirectory,
                scrollbackLines: settings.scrollbackLines,
                // Seed COLORFGBG from the pane's preset so the shell launches
                // with the right light/dark hint (issue #8).
                lightBackground: ColorScheme.resolve(for: tab.preset).isLightBackground,
                restoringFrom: snapshot)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not start shell"
            alert.informativeText = String(describing: error)
            alert.runModal()
            return nil
        }
        let pane = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        // A restored leaf carries its session UUID forward so re-saves
        // overwrite the same `.crtstate` file.
        if let sessionID { pane.sessionID = sessionID }
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
        pane.rendererProvider = { [weak self, weak pane] in
            guard let self else { return nil }
            let preset = pane?.preset
            // A preset that forces its own face wins (the C64 1702); otherwise
            // the user's chosen font, falling back to bundled Geist Mono.
            return self.rendererForPane(
                name: preset?.fontName ?? self.settings.fontName ?? BundledFonts.geistMono,
                scale: preset?.fontSizeScale ?? 1)
        }
        guard let session = pane.session else { return }
        session.onExit = { [weak self, weak pane] _ in
            guard let pane else { return }
            self?.close(pane: pane)
        }
        session.onNotification = { [weak self, weak pane] notification in
            guard let self else { return }
            if let pane { self.noteAttention(in: pane) }
            NotificationPoster.shared.post(
                notification, windowIsKey: self.window?.isKeyWindow ?? false,
                sessionID: pane.flatMap { pane in
                    self.tabs.first { $0.panes.contains(pane) }?.id
                })
        }
        pane.onBell = { [weak self, weak pane] in
            guard let pane else { return }
            self?.noteBell(in: pane)
        }
    }

    // MARK: Attention (sidebar bell badges)

    /// Sessions here with unseen bells; the dock badge sums these.
    var attentionSessionCount: Int {
        tabs.filter { $0.unseenBells > 0 }.count
    }

    /// A bell or notification fired in this pane's session. Unless the
    /// user is watching it — active tab in the key window of the active
    /// app — badge the sidebar row until the tab is next viewed.
    private func noteAttention(in pane: TerminalView) {
        guard let index = tabs.firstIndex(where: { $0.panes.contains(pane) })
        else { return }
        let watched = index == activeTabIndex
            && window?.isKeyWindow == true && NSApp.isActive
        guard !watched else { return }
        tabs[index].unseenBells += 1
        tabs[index].lastBellAt = Date()
        refreshSessionMetadata()
        AppDelegate.shared?.bellRequiresAttention()
    }

    /// BEL: badge via noteAttention, plus a notification when the whole
    /// app is in the background — titled with the ringing command, the
    /// session and its directory in the body ("claude / Session 2 ·
    /// ~/dev/app"), so a stack of notifications tells the sessions apart.
    private func noteBell(in pane: TerminalView) {
        noteAttention(in: pane)
        guard let index = tabs.firstIndex(where: { $0.panes.contains(pane) }),
              let session = pane.session else { return }
        let shellPID = session.shellProcessID
        let foreground = session.foregroundProcessGroup
        let isRunning = foreground > 0 && foreground != shellPID
        let command = isRunning ? SessionInfo.processName(of: foreground) : nil
        let title = command ?? session.snapshot.title
            ?? SessionInfo.processName(of: shellPID) ?? "Shell"
        let cwd = SessionInfo.workingDirectory(of: isRunning ? foreground : shellPID)
            ?? SessionInfo.workingDirectory(of: shellPID)
        var details = ["Session \(index + 1)"]
        if let cwd { details.append(SessionInfo.abbreviate(path: cwd)) }
        NotificationPoster.shared.postBell(
            sessionID: tabs[index].id,
            title: title,
            body: details.joined(separator: " · "))
    }

    /// Viewing the active tab consumes its attention badge.
    func windowDidBecomeKey(_ notification: Notification) {
        if let tab = activeTab, tab.unseenBells > 0 {
            tab.unseenBells = 0
            refreshSessionMetadata()
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
        // Only reserve the sidebar rail when it's actually showing.
        let sidebarWidth = sidebar.isHidden ? 0 : SessionSidebarView.width
        window.setContentSize(NSSize(
            width: size.width + sidebarWidth, height: size.height))
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
        noteSignificantChange()
    }

    private func tab(owning pane: TerminalView) -> SessionTab? {
        tabs.first { $0.panes.contains { $0 === pane } }
    }

    /// Closes a pane; the last pane closing closes the session, the last
    /// session closing closes the window.
    func close(pane: TerminalView) {
        pane.session?.terminate()
        pane.renderLoop?.invalidate()
        // An explicitly closed pane won't come back — drop its stored state so
        // it doesn't leak as a stray `.crtstate` file.
        SessionStateStore.shared.discard(id: pane.sessionID)
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
        noteSignificantChange()
    }

    /// Closes a whole sidebar session — every pane in it (the row's ✕).
    func closeSession(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        // Confirm before terminating this session's live panes (idle
        // shells/multiplexers don't count). Done here rather than via
        // windowShouldClose because close(pane:) kills panes eagerly.
        let running = tabs[index].panes.compactMap { $0.session?.runningProcessName }
        if !running.isEmpty,
           !CloseConfirmation.confirm(processNames: running, verb: "Close") {
            return
        }
        for pane in tabs[index].panes {
            close(pane: pane)
        }
    }

    // MARK: Session restoration (R1: debug-driven, single session)

    /// Snapshot the focused session and persist it, keyed by its owning tab's
    /// UUID, capturing the shell's live cwd now (the shell is alive at save
    /// time, so `proc_pidinfo` answers without OSC 7 — that's an R4
    /// robustness add). Returns the tab id that was saved.
    @discardableResult
    func saveFocusedSessionState() -> UUID? {
        guard let pane = focusedPane else { return nil }
        saveContents(of: pane)
        return pane.sessionID
    }

    /// Snapshot one pane's terminal contents (grid + scrollback) and persist
    /// it keyed by the pane's session UUID, capturing the shell's live cwd.
    /// `synchronously` is for the quit path, where the write must finish
    /// before the shells are SIGHUP'd and the process dies.
    func saveContents(of pane: TerminalView, synchronously: Bool = false) {
        guard let session = pane.session else { return }
        let state = session.snapshot
        // Nothing visible changed since the last save → the file on disk is
        // still current; skip the encode + write. This is what keeps a quit
        // after the screen settles from re-writing every session.
        if pane.lastSavedGeneration == state.generation { return }
        // Prefer the shell's live OSC 7 report (survives a cd since the last
        // 1 Hz probe); fall back to the kernel query.
        let cwd = state.currentDirectory
            ?? SessionInfo.workingDirectory(of: session.shellProcessID)
        let snapshot = state.makeSnapshot(workingDirectoryHint: cwd)
        if synchronously {
            SessionStateStore.shared.saveSynchronously(snapshot, for: pane.sessionID)
        } else {
            SessionStateStore.shared.save(snapshot, for: pane.sessionID)
        }
        pane.lastSavedGeneration = state.generation
    }

    /// Persist every pane in this window (called before capturing layout).
    func saveAllContents(synchronously: Bool = false) {
        for pane in panes { saveContents(of: pane, synchronously: synchronously) }
    }

    /// All session UUIDs alive in this window (for orphan-file pruning).
    var liveSessionIDs: [UUID] { panes.map(\.sessionID) }

    /// Open a new session restoring the given snapshot and select it.
    @discardableResult
    func restoreSession(from snapshot: TerminalStateSnapshot) -> SessionTab? {
        addSession(restoringFrom: snapshot)
    }

    // MARK: Layout capture / rebuild (R2)

    /// Capture this window's full layout — frame, active tab, and each tab's
    /// split tree — by walking the live view hierarchy (the tree isn't in
    /// `panes`, only the flattened pane list is).
    func captureLayout() -> WindowNode {
        let tabNodes = tabs.compactMap { tab -> TabNode? in
            guard let rootView = tab.container.subviews.first,
                  let root = Self.captureSplitNode(from: rootView) else { return nil }
            return TabNode(
                uuid: tab.id, presetName: tab.preset.name, root: root,
                customName: tab.customName)
        }
        return WindowNode(
            frame: window?.frame ?? .zero,
            activeTabIndex: activeTabIndex,
            tabs: tabNodes)
    }

    private static func captureSplitNode(from view: NSView) -> SplitNode? {
        if let pane = view as? TerminalView {
            return .leaf(sessionID: pane.sessionID)
        }
        if let split = view as? NSSplitView {
            let children = split.arrangedSubviews.compactMap(captureSplitNode(from:))
            guard !children.isEmpty else { return nil }
            return .split(
                isVertical: split.isVertical,
                dividerFractions: dividerFractions(of: split),
                children: children)
        }
        return nil
    }

    /// Cumulative divider positions as a fraction of the split's length,
    /// one per divider (children − 1). Flip-independent: built from pane
    /// sizes along the split axis.
    private static func dividerFractions(of split: NSSplitView) -> [Double] {
        let vertical = split.isVertical
        let total = vertical ? split.bounds.width : split.bounds.height
        let subs = split.arrangedSubviews
        guard total > 0, subs.count > 1 else { return [] }
        var fractions: [Double] = []
        var cumulative: CGFloat = 0
        for i in 0..<(subs.count - 1) {
            cumulative += vertical ? subs[i].frame.width : subs[i].frame.height
            fractions.append(Double(cumulative / total))
            cumulative += split.dividerThickness
        }
        return fractions
    }

    /// Rebuild this (initially empty) window from a captured node: recreate
    /// the tabs and their nested `NSSplitView`s, `makePane`-ing each leaf with
    /// its restored session, then apply divider fractions after layout.
    func restoreLayout(_ node: WindowNode, contents: SessionStateStore) {
        if let window, node.frame.width > 1, node.frame.height > 1 {
            window.setFrame(node.frame, display: false)
        }
        var roots: [(SplitNode, NSView)] = []
        for tabNode in node.tabs {
            let preset = PresetCatalog.all.first { $0.name == tabNode.presetName }
                ?? currentPreset()
            let tab = SessionTab(preset: preset)
            tab.customName = tabNode.customName
            tab.container.frame = contentHost.bounds
            tab.container.autoresizingMask = [.width, .height]
            contentHost.addSubview(tab.container)
            tabs.append(tab)
            guard let rootView = buildSplitNode(tabNode.root, in: tab, contents: contents)
            else { continue }
            rootView.frame = tab.container.bounds
            rootView.autoresizingMask = [.width, .height]
            tab.container.addSubview(rootView)
            roots.append((tabNode.root, rootView))
        }
        guard !tabs.isEmpty else { return }
        selectTab(min(max(0, node.activeTabIndex), tabs.count - 1))
        // Sizes are settled now (window frame + sidebar inset applied), so
        // divider fractions land where they were captured.
        contentHost.layoutSubtreeIfNeeded()
        for (node, view) in roots {
            Self.applyDividers(node, to: view)
        }
    }

    private func buildSplitNode(
        _ node: SplitNode, in tab: SessionTab, contents: SessionStateStore
    ) -> NSView? {
        switch node {
        case .leaf(let sessionID):
            let snapshot = contents.load(for: sessionID)
            return makePane(in: tab, restoringFrom: snapshot, sessionID: sessionID)
        case .split(let isVertical, _, let children):
            let split = NSSplitView()
            split.isVertical = isVertical
            split.dividerStyle = .thin
            for child in children {
                guard let childView = buildSplitNode(child, in: tab, contents: contents)
                else { continue }
                childView.autoresizingMask = [.width, .height]
                split.addArrangedSubview(childView)
            }
            guard !split.arrangedSubviews.isEmpty else { return nil }
            split.adjustSubviews()
            return split
        }
    }

    private static func applyDividers(_ node: SplitNode, to view: NSView) {
        guard case .split(let vertical, let fractions, let children) = node,
              let split = view as? NSSplitView else { return }
        let total = vertical ? split.bounds.width : split.bounds.height
        if total > 0 {
            for (i, fraction) in fractions.enumerated()
            where i < split.arrangedSubviews.count - 1 {
                split.setPosition(CGFloat(fraction) * total, ofDividerAt: i)
            }
        }
        // Inner splits resized by the positions above; apply theirs now.
        for (child, childView) in zip(children, split.arrangedSubviews) {
            applyDividers(child, to: childView)
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
        noteSignificantChange()
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
        noteSignificantChange()
    }

    /// ⌘W: close the focused pane (the window when it's the only one).
    @objc func closePane(_ sender: Any?) {
        guard let pane = focusedPane else {
            window?.close()
            return
        }
        // `close(pane:)` terminates the pane before any cascade to
        // window.close(), so confirm here (windowShouldClose would see it
        // already gone) — no double prompt results.
        if let name = pane.session?.runningProcessName,
           !CloseConfirmation.confirm(processNames: [name], verb: "Close") {
            return
        }
        close(pane: pane)
    }

    // MARK: Sidebar metadata

    /// The name shown for a tab: the user's custom name when set (non-empty),
    /// otherwise the inferred one — the shell's OSC title, falling back to the
    /// process/shell name. Single source of truth for the row, hover card, and
    /// window title.
    func displayTitle(for tab: SessionTab) -> String {
        if let custom = tab.customName, !custom.isEmpty { return custom }
        let session = tab.panes.first?.session
        let shellName = session.flatMap { SessionInfo.processName(of: $0.shellProcessID) }
            ?? (settings.shellPath as NSString?)?.lastPathComponent ?? "shell"
        return session?.snapshot.title ?? shellName
    }

    /// Apply a user-chosen name to a session (empty/whitespace reverts to the
    /// automatic name), then refresh the sidebar and persist the new layout.
    func renameSession(id: UUID, to newName: String?) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        refreshSessionMetadata()
        noteSignificantChange()
    }

    /// Cheap kernel probes each tick; git runs async behind a short cache.
    /// Internal so alert-settings changes can re-apply without waiting a tick.
    func refreshSessionMetadata() {
        var rows: [SessionRowModel] = []
        // Every row shares the active session's surface (light/dark), so the
        // rail reads as one coherent surface; each row's accent is its own.
        let surfacePreset = activePreset
        for (index, tab) in tabs.enumerated() {
            guard let session = tab.panes.first?.session else { continue }
            let shellPID = session.shellProcessID
            let foreground = session.foregroundProcessGroup
            let isRunning = foreground > 0 && foreground != shellPID
            let shellName = SessionInfo.processName(of: shellPID)
                ?? (settings.shellPath as NSString?)?.lastPathComponent ?? "shell"
            let automaticName = session.snapshot.title ?? shellName
            let title = displayTitle(for: tab)
            let cwd = SessionInfo.workingDirectory(of: isRunning ? foreground : shellPID)
                ?? SessionInfo.workingDirectory(of: shellPID)
            var metaLine: String
            if isRunning {
                let name = SessionInfo.processName(of: foreground) ?? "…"
                metaLine = "\(name) · live"
            } else {
                metaLine = cwd.map(SessionInfo.displayName(path:)) ?? shellName
            }
            let progress = session.snapshot.progress
            if let progress, progress.state != .indeterminate {
                metaLine += " · \(progress.percent)%"
            }
            rows.append(SessionRowModel(
                id: tab.id, index: index + 1, title: title,
                customName: tab.customName, automaticName: automaticName,
                metaLine: metaLine,
                isActive: index == activeTabIndex, isRunning: isRunning,
                dirtyCount: dirtyCounts[tab.id],
                attentionCount: AlertSettings.shared.sidebarBadges
                    && tab.unseenBells > 0 ? tab.unseenBells : nil,
                progress: progress,
                theme: SidebarTheme(surface: surfacePreset, accent: tab.preset)))
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
        AppDelegate.shared?.refreshDockBadge()
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
            title: displayTitle(for: tab),
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
            exitLine: lastExit.map { $0 == 0 ? "✓ 0" : "✗ \($0)" },
            bellLine: tab.unseenBells > 0 ? tab.lastBellAt.map {
                "rang \(Self.format(uptime: -$0.timeIntervalSinceNow)) ago"
            } : nil)

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
        let bar = SearchBar(frame: .zero, preset: activePreset)
        bar.onSearch = { [weak self] query, options, backward in
            self?.focusedPane?.find(query, options: options, backward: backward) ?? .none
        }
        bar.onQueryChange = { [weak self] query, options in
            self?.focusedPane?.updateSearch(query, options: options) ?? .none
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
        // Let the grid keep revealed matches clear of the bar's footprint.
        for pane in panes {
            pane.searchBarOverlap = height
        }
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
            pane.searchBarOverlap = 0
            pane.endSearch()
        }
        if let pane = focusedPane {
            window?.makeFirstResponder(pane)
        }
    }

    // MARK: Settings

    /// Re-applies edited settings. A font change rebuilds the window's
    /// shared renderer. The settings preset is only the default for new
    /// sessions — existing sessions keep the theme they're wearing.
    func apply(settings: TerminalSettings) {
        let fontChanged = settings.font != self.settings.font
        self.settings = settings
        if fontChanged {
            sharedRenderers.removeAll()
            for pane in panes {
                pane.resetRenderer()
            }
        }
        for renderer in sharedRenderers.values {
            renderer.setLigatures(settings.ligatures)
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
            // Themes the active session only — it does not touch the default
            // theme, so new sessions and windows keep starting from the
            // Settings default rather than the last switch.
            self?.apply(preset: preset)
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the window kills every pane in it: confirm if any still has
        // a foreground process running (idle shells/multiplexers don't count).
        let running = panes.compactMap { $0.session?.runningProcessName }
        return running.isEmpty
            || CloseConfirmation.confirm(processNames: running, verb: "Close")
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

/// The slide-down find bar: a `/`-led search field with a live `N / total`
/// match counter and prev/next; Esc dismisses. Colours track the active
/// preset so it wears the same theme as the sidebar and titlebar chrome.
final class SearchBar: NSView, NSSearchFieldDelegate {
    private let field = NSSearchField()
    private let slash = NSTextField(labelWithString: "/")
    private let counter = NSTextField(labelWithString: "")
    private let theme: SidebarTheme
    /// The grep-style flag chips, in bar order: match-case, whole-word, regex.
    private var caseChip: NSButton!
    private var wordChip: NSButton!
    private var regexChip: NSButton!
    /// Stepping: query + options + backward flag. Returns the counter summary.
    var onSearch: ((String, SearchOptions, Bool) -> SearchSummary)?
    /// Live re-search as the query or options change. Returns the summary.
    var onQueryChange: ((String, SearchOptions) -> SearchSummary)?
    var onDismiss: (() -> Void)?
    private var lastSummary: SearchSummary = .none

    init(frame frameRect: NSRect, preset: CRTPreset) {
        theme = SidebarTheme(preset: preset)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = theme.cardBackground.cgColor

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = theme.separator.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        slash.font = .monospacedSystemFont(ofSize: 15, weight: .heavy)
        slash.textColor = theme.accent
        slash.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slash)

        field.placeholderString = "Search scrollback"
        field.delegate = self
        field.target = self
        field.action = #selector(searchSubmitted(_:))
        field.textColor = theme.text
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        counter.font = .monospacedSystemFont(ofSize: 11.5, weight: .bold)
        counter.textColor = theme.dim
        counter.alignment = .right
        counter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(counter)

        // grep-style flag chips; initial state restored from the shared,
        // persisted SearchSettings so it carries across tabs and restarts.
        let saved = SearchSettings.shared
        caseChip = makeChip(title: "Aa", accessibility: "Match case", on: saved.caseSensitive)
        wordChip = makeChip(title: "\\b", accessibility: "Whole word", on: saved.wholeWord)
        regexChip = makeChip(title: ".*", accessibility: "Regular expression", on: saved.regex)

        let previous = NSButton(
            image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous match")!,
            target: self, action: #selector(findPrevious(_:)))
        let next = NSButton(
            image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next match")!,
            target: self, action: #selector(findNext(_:)))
        let done = NSButton(title: "Done", target: self, action: #selector(dismiss(_:)))
        previous.contentTintColor = theme.accent
        next.contentTintColor = theme.accent
        for button in [previous, next, done] {
            button.bezelStyle = .accessoryBarAction
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            slash.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            slash.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: slash.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            caseChip.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            caseChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            wordChip.leadingAnchor.constraint(equalTo: caseChip.trailingAnchor, constant: 4),
            wordChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            regexChip.leadingAnchor.constraint(equalTo: wordChip.trailingAnchor, constant: 4),
            regexChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            counter.leadingAnchor.constraint(equalTo: regexChip.trailingAnchor, constant: 10),
            counter.centerYAnchor.constraint(equalTo: centerYAnchor),
            counter.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            previous.leadingAnchor.constraint(equalTo: counter.trailingAnchor, constant: 8),
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

    /// A pill toggle wearing the active preset's accent when on, dim when off.
    private func makeChip(title: String, accessibility: String, on: Bool) -> NSButton {
        let chip = NSButton(title: title, target: self, action: #selector(chipToggled(_:)))
        chip.setButtonType(.pushOnPushOff)
        chip.bezelStyle = .accessoryBarAction
        chip.font = .monospacedSystemFont(ofSize: 11.5, weight: .bold)
        chip.setAccessibilityLabel(accessibility)
        chip.toolTip = accessibility
        chip.state = on ? .on : .off
        chip.contentTintColor = on ? theme.accent : theme.dim
        chip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chip)
        return chip
    }

    /// The flag chips' current state as a `SearchOptions`.
    private var currentOptions: SearchOptions {
        SearchOptions(
            caseSensitive: caseChip.state == .on,
            wholeWord: wordChip.state == .on,
            regex: regexChip.state == .on)
    }

    @objc private func chipToggled(_ sender: NSButton) {
        sender.contentTintColor = sender.state == .on ? theme.accent : theme.dim
        // Persist so the choice survives across tabs, windows, and restarts.
        let settings = SearchSettings.shared
        settings.caseSensitive = caseChip.state == .on
        settings.wholeWord = wordChip.state == .on
        settings.regex = regexChip.state == .on
        // Re-run live against the current query.
        if let summary = onQueryChange?(field.stringValue, currentOptions) {
            setCounter(summary)
        }
    }

    func repeatSearch(backward: Bool) {
        guard !field.stringValue.isEmpty else { return }
        if let summary = onSearch?(field.stringValue, currentOptions, backward) {
            setCounter(summary)
        }
    }

    /// Updates the counter label. An empty query shows nothing; an invalid
    /// regex shows "bad regex"; otherwise "N / total" or "no results".
    func setCounter(_ summary: SearchSummary) {
        lastSummary = summary
        if field.stringValue.isEmpty {
            counter.stringValue = ""
        } else if summary.badRegex {
            counter.stringValue = "bad regex"
            counter.textColor = theme.amber
        } else if summary.total == 0 {
            counter.stringValue = "no results"
            counter.textColor = theme.faint
        } else {
            counter.stringValue = "\(summary.current) / \(summary.total)"
            counter.textColor = theme.text
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if let summary = onQueryChange?(field.stringValue, currentOptions) {
            setCounter(summary)
        }
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
