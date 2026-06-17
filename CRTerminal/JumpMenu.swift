import AppKit
import TerminalCore

/// Anything the floating palette can present: a searchable item (facets feed
/// `JumpSearch.rank`) that renders as a two-line row.
protocol PaletteItem: JumpSearchable {
    var title: String { get }
    var subtitle: String { get }
}

/// One jumpable session (a sidebar tab in some window), with the facets
/// the palette searches and the lines it displays.
struct JumpTarget: PaletteItem {
    weak var controller: TerminalWindowController?
    let tabID: UUID
    let title: String
    let subtitle: String
    let facets: [SessionFacet]
}

/// Everything a facet provider may inspect about one session tab.
struct JumpFacetContext {
    let tab: SessionTab
    /// Sessions of every pane in the tab (splits make several).
    let sessions: [TerminalSession]
    let windowNumber: Int
    let shellFallbackName: String
}

/// Builds jump targets across every window. To make a new session
/// attribute searchable in the future, append a provider to
/// `extraProviders` — the matcher and UI need no changes (unknown kinds
/// rank and display like any other).
@MainActor
enum JumpTargetBuilder {
    typealias FacetProvider = @MainActor (JumpFacetContext) -> [SessionFacet]

    /// The extension point: register a provider here to make a new session
    /// attribute searchable (and visible in the result subtitle).
    static var extraProviders: [FacetProvider] = []

    /// Each provider derives zero or more facets per session tab.
    static var facetProviders: [FacetProvider] {
        [titleFacets, commandFacets, directoryFacets, branchFacets] + extraProviders
    }

    static func targets(
        across controllers: [TerminalWindowController]
    ) -> [JumpTarget] {
        var targets: [JumpTarget] = []
        for (windowIndex, controller) in controllers.enumerated() {
            for tab in controller.tabs {
                let sessions = tab.panes.compactMap(\.session)
                guard !sessions.isEmpty else { continue }
                let context = JumpFacetContext(
                    tab: tab,
                    sessions: sessions,
                    windowNumber: windowIndex + 1,
                    shellFallbackName: "shell")
                let facets = facetProviders.flatMap { $0(context) }
                targets.append(JumpTarget(
                    controller: controller,
                    tabID: tab.id,
                    title: facets.first { $0.kind == "title" }?.text ?? "session",
                    subtitle: subtitle(
                        context: context, facets: facets,
                        showWindow: controllers.count > 1),
                    facets: facets))
            }
        }
        return targets
    }

    /// "Window 2 · claude · ~/dev/mcq-master · ⎇ main" — built from the
    /// same facets the search sees, so anything findable is also visible.
    private static func subtitle(
        context: JumpFacetContext, facets: [SessionFacet], showWindow: Bool
    ) -> String {
        var parts: [String] = []
        if showWindow { parts.append("Window \(context.windowNumber)") }
        for facet in facets where facet.kind != "title" {
            parts.append(facet.kind == "branch" ? "⎇ \(facet.text)" : facet.text)
        }
        if context.sessions.count > 1 {
            parts.append("\(context.sessions.count) panes")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Built-in providers

    private static func titleFacets(_ context: JumpFacetContext) -> [SessionFacet] {
        guard let session = context.sessions.first else { return [] }
        let shellName = SessionInfo.processName(of: session.shellProcessID)
            ?? context.shellFallbackName
        let title = session.snapshot.title ?? shellName
        return [SessionFacet(kind: "title", text: title, weight: 2)]
    }

    /// The foreground command of each pane (the shell's name when idle).
    private static func commandFacets(_ context: JumpFacetContext) -> [SessionFacet] {
        var facets: [SessionFacet] = []
        for session in context.sessions {
            let shellPID = session.shellProcessID
            let foreground = session.foregroundProcessGroup
            let isRunning = foreground > 0 && foreground != shellPID
            let pid = isRunning ? foreground : shellPID
            if let name = SessionInfo.processName(of: pid) {
                facets.append(SessionFacet(kind: "command", text: name, weight: 1.5))
            }
        }
        return dedupe(facets)
    }

    private static func directoryFacets(_ context: JumpFacetContext) -> [SessionFacet] {
        dedupe(workingDirectories(of: context).map {
            SessionFacet(kind: "directory", text: SessionInfo.abbreviate(path: $0))
        })
    }

    private static func branchFacets(_ context: JumpFacetContext) -> [SessionFacet] {
        dedupe(workingDirectories(of: context).compactMap {
            SessionInfo.gitBranch(near: $0).map {
                SessionFacet(kind: "branch", text: $0)
            }
        })
    }

    private static func workingDirectories(of context: JumpFacetContext) -> [String] {
        context.sessions.compactMap { session in
            let shellPID = session.shellProcessID
            let foreground = session.foregroundProcessGroup
            let isRunning = foreground > 0 && foreground != shellPID
            return SessionInfo.workingDirectory(of: isRunning ? foreground : shellPID)
                ?? SessionInfo.workingDirectory(of: shellPID)
        }
    }

    /// Split panes often share a cwd/command; one facet per distinct value.
    private static func dedupe(_ facets: [SessionFacet]) -> [SessionFacet] {
        var seen = Set<String>()
        return facets.filter { seen.insert($0.text).inserted }
    }
}

// MARK: - Panel UI

/// Borderless panels refuse key status unless told otherwise; the palette
/// needs it for typing.
private final class JumpPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The floating palette behind ⌘K (sessions) and ⌘⇧K / ⌘⌥K (command
/// history): a field + result list over the key window. Type to filter,
/// ↑/↓ to choose, ⏎ to act, Esc (or clicking away) to dismiss.
final class PaletteController<Item: PaletteItem>: NSObject, NSTextFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private static var width: CGFloat { 600 }
    private static var fieldHeight: CGFloat { 50 }
    private static var rowHeight: CGFloat { 44 }
    private static var maxVisibleRows: Int { 8 }

    private let panel: JumpPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel: NSTextField
    private let allTargets: [Item]
    private var results: [Item]
    private let theme: SidebarTheme
    private let onSelect: (Item) -> Void
    var onDismiss: (() -> Void)?
    /// Top edge stays anchored while the panel grows/shrinks with results.
    private var anchoredTop: CGFloat = 0

    init(
        targets: [Item], theme: SidebarTheme,
        placeholder: String = "Jump to session — command, directory, branch…",
        emptyText: String = "No matching sessions",
        onSelect: @escaping (Item) -> Void
    ) {
        allTargets = targets
        results = targets
        self.theme = theme
        self.onSelect = onSelect
        emptyLabel = NSTextField(labelWithString: emptyText)
        panel = JumpPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.delegate = self
        panel.isReleasedWhenClosed = false

        let chrome = NSView()
        chrome.wantsLayer = true
        chrome.layer?.backgroundColor = theme.cardBackground.cgColor
        chrome.layer?.cornerRadius = 14
        chrome.layer?.borderWidth = 1
        chrome.layer?.borderColor = theme.cardBorder.cgColor
        chrome.layer?.masksToBounds = true
        panel.contentView = chrome

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18, weight: .light)
        field.textColor = theme.text
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: theme.faint,
                         .font: NSFont.systemFont(ofSize: 18, weight: .light)])
        field.delegate = self
        chrome.addSubview(field)

        let column = NSTableColumn(identifier: .init("session"))
        column.width = Self.width
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.allowsEmptySelection = false

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        chrome.addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = theme.dim
        emptyLabel.alignment = .center
        chrome.addSubview(emptyLabel)
    }

    /// `initiallySelecting` highlights a starting row (e.g. the focused
    /// session) instead of the first; out-of-range values clamp to it.
    func show(over hostWindow: NSWindow?, initiallySelecting row: Int = 0) {
        let screenFrame = (hostWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let host = hostWindow?.frame ?? screenFrame
        // Centered on the host window, field about a quarter down.
        anchoredTop = min(host.maxY - 80, screenFrame.maxY - 40)
        let x = host.midX - Self.width / 2
        layout(panelOriginX: max(screenFrame.minX + 20, x))
        table.reloadData()
        selectRow(row)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func dismiss() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        onDismiss?()
    }

    // MARK: Layout

    private func layout(panelOriginX: CGFloat? = nil) {
        let rows = min(results.count, Self.maxVisibleRows)
        let listHeight = results.isEmpty
            ? 36 : CGFloat(rows) * Self.rowHeight + 6
        let height = Self.fieldHeight + listHeight
        let x = panelOriginX ?? panel.frame.origin.x
        panel.setFrame(
            NSRect(x: x, y: anchoredTop - height, width: Self.width, height: height),
            display: true)
        guard let chrome = panel.contentView else { return }
        field.frame = NSRect(
            x: 18, y: chrome.bounds.height - Self.fieldHeight + 14,
            width: chrome.bounds.width - 36, height: 24)
        scroll.frame = NSRect(
            x: 0, y: 0, width: chrome.bounds.width,
            height: chrome.bounds.height - Self.fieldHeight)
        scroll.isHidden = results.isEmpty
        emptyLabel.frame = NSRect(
            x: 0, y: 10, width: chrome.bounds.width, height: 18)
        emptyLabel.isHidden = !results.isEmpty
    }

    // MARK: Querying

    func controlTextDidChange(_ notification: Notification) {
        results = JumpSearch.rank(allTargets, query: field.stringValue)
        // Reload before the panel resize: relayout while the table still
        // holds the old row count would ask for rows `results` no longer has.
        table.reloadData()
        layout()
        selectRow(0)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            selectRow(table.selectedRow - 1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            selectRow(table.selectedRow + 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            choose(row: table.selectedRow)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }

    /// Probe/test entry: set the query as if typed.
    func setQuery(_ query: String) {
        field.stringValue = query
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    /// Probe/test entry: how many rows the current query matched.
    var resultCount: Int { results.count }

    /// Probe/test entry: capture the rendered panel.
    func writeSnapshot(to path: String) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    private func selectRow(_ row: Int) {
        guard !results.isEmpty else { return }
        let clamped = min(max(0, row), results.count - 1)
        table.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        table.scrollRowToVisible(clamped)
    }

    func choose(row: Int) {
        guard results.indices.contains(row) else { return }
        let target = results[row]
        dismiss()
        onSelect(target)
    }

    @objc private func rowClicked(_ sender: Any?) {
        choose(row: table.clickedRow)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("jumpRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? JumpRowView ?? JumpRowView(identifier: identifier, theme: theme)
        view.update(title: results[row].title, subtitle: results[row].subtitle)
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        JumpRowBackground(accent: theme.accent)
    }

    // MARK: Window

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}

/// Rounded accent-tinted selection, matching the sidebar's row treatment.
private final class JumpRowBackground: NSTableRowView {
    private let accent: NSColor

    init(accent: NSColor) {
        self.accent = accent
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("JumpRowBackground is created in code")
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 6, dy: 2)
        accent.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }
}

/// Two-line result row: session title over its facet summary.
private final class JumpRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, theme: SidebarTheme) {
        super.init(frame: .zero)
        self.identifier = identifier
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = theme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = theme.dim
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(titleLabel)
        addSubview(subtitleLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("JumpRowView is created in code")
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(
            x: 18, y: bounds.height - 21, width: bounds.width - 36, height: 17)
        subtitleLabel.frame = NSRect(
            x: 18, y: 5, width: bounds.width - 36, height: 15)
    }

    func update(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        needsLayout = true
    }
}
