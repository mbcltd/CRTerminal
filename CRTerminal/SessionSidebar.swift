import AppKit
import CRTRendering
import TerminalCore

// The vertical session sidebar from the GlassTerm design handoff: rich
// rows (accent bar, icon chip, running pulse, metadata line) with a hover
// detail card per session. Chrome colors derive from the active preset so
// the sidebar wears the same phosphor as the tube next to it.

/// Sidebar/hover-card palette. The *surface* (background, text, the whole
/// legibility baseline) comes from the active session, so the rail reads as
/// one coherent light-or-dark surface no matter how its tabs are themed; a
/// row's *accent* hue identifies its own session on top of that surface.
/// Every derived colour is contrast-clamped against the surface, so any mix
/// of light, dark and CRT sessions stays legible.
struct SidebarTheme: Equatable {
    enum Mode { case dark, light }
    var mode: Mode
    var accent: NSColor
    var green: NSColor
    var amber: NSColor
    var text: NSColor
    var dim: NSColor
    var faint: NSColor
    var chip: NSColor
    var separator: NSColor
    var background: NSColor
    var cardBackground: NSColor
    var cardBorder: NSColor

    /// A whole-surface theme — the rail chrome, or a session's own
    /// self-contained hover card — taking both surface and accent from one
    /// preset.
    init(preset: CRTPreset) {
        self.init(surface: preset, accent: preset)
    }

    /// A row theme: the surface (and thus light/dark mode) comes from the
    /// `surface` preset — the active session — while the accent hue comes
    /// from this row's own `accent` preset.
    init(surface: CRTPreset, accent accentPreset: CRTPreset) {
        let mode: Mode = Self.isLightSurface(surface) ? .light : .dark
        self.mode = mode

        // Surface: near-black or near-paper, faintly tinted by the active
        // session's identity so the rail still "wears the tube" beside it.
        let surfaceTint = Self.identityColor(for: surface)
        let bgBase = mode == .light
            ? NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)
            : NSColor(srgbRed: 0.02, green: 0.03, blue: 0.02, alpha: 1)
        let bg = bgBase.blended(withFraction: 0.05, of: surfaceTint) ?? bgBase
        background = bg
        let cardBase = mode == .light
            ? NSColor(srgbRed: 0.99, green: 0.99, blue: 1.0, alpha: 0.98)
            : NSColor(srgbRed: 0.04, green: 0.055, blue: 0.045, alpha: 0.97)
        cardBackground = cardBase.blended(withFraction: 0.05, of: surfaceTint) ?? cardBase

        // Accent: this session's identity hue, nudged just enough to read.
        let rawAccent = Self.identityColor(for: accentPreset)
        accent = Self.legible(rawAccent, on: bg, minContrast: 3.2)

        // Monochrome tubes have exactly one colour; everything else gets
        // conventional status colours, each clamped to the surface.
        let monochrome = accentPreset.effects && accentPreset.phosphor.monochrome
        green = monochrome ? accent
            : Self.legible(.systemGreen, on: bg, minContrast: 3.2)
        amber = monochrome ? accent
            : Self.legible(NSColor(srgbRed: 0.88, green: 0.69, blue: 0.41, alpha: 1),
                           on: bg, minContrast: 3.2)

        // Text ladder pinned to the surface ink, faintly tinted by the
        // accent so a row keeps a whisper of its session's colour.
        let ink: NSColor = mode == .light ? .black : .white
        let body = Self.legible(
            ink.blended(withFraction: 0.18, of: rawAccent) ?? ink, on: bg, minContrast: 7)
        text = body
        dim = body.withAlphaComponent(0.62)
        faint = body.withAlphaComponent(0.34)

        chip = accent.withAlphaComponent(mode == .light ? 0.14 : 0.09)
        separator = (mode == .light ? NSColor.black : accent).withAlphaComponent(0.16)
        cardBorder = accent.withAlphaComponent(0.3)
    }

    /// A session's identity colour: a CRT tube glows in its phosphor; the
    /// plain presets use their own scheme's ink — a near-white glow for the
    /// dark standard, a dark slate for the light one.
    private static func identityColor(for preset: CRTPreset) -> NSColor {
        if preset.effects { return NSColor(preset.phosphor.color) }
        // A custom palette identifies itself by its accent hue (the bright
        // red of the "Danger" theme), so the rail wears its colour too.
        if let colors = preset.colors { return NSColor(colors.red ?? colors.foreground) }
        return preset.appearance == .light
            ? NSColor(srgbRed: 0.20, green: 0.22, blue: 0.28, alpha: 1)
            : NSColor(srgbRed: 0.91, green: 0.92, blue: 0.96, alpha: 1)
    }

    /// Whether a preset's surface reads as light: a custom palette decides by
    /// its background luminance, otherwise `appearance` says so directly.
    private static func isLightSurface(_ preset: CRTPreset) -> Bool {
        if let colors = preset.colors {
            return relativeLuminance(NSColor(colors.background)) > 0.5
        }
        return preset.appearance == .light
    }

    // MARK: Contrast

    /// `color` nudged toward white (on a dark surface) or black (on a light
    /// one) just until it clears `minContrast` against `background` — so a
    /// session's hue survives while staying readable on any rail.
    static func legible(
        _ color: NSColor, on background: NSColor, minContrast: CGFloat
    ) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB),
              let bg = background.usingColorSpace(.sRGB) else { return color }
        if contrastRatio(c, bg) >= minContrast { return c }
        let target: NSColor = relativeLuminance(bg) < 0.5 ? .white : .black
        var lo: CGFloat = 0, hi: CGFloat = 1, best = target
        for _ in 0..<14 {
            let mid = (lo + hi) / 2
            let candidate = c.blended(withFraction: mid, of: target) ?? c
            if contrastRatio(candidate, bg) >= minContrast {
                best = candidate
                hi = mid
            } else {
                lo = mid
            }
        }
        return best
    }

    /// WCAG relative luminance of an sRGB colour (alpha ignored).
    static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent)
            + 0.7152 * lin(c.greenComponent)
            + 0.0722 * lin(c.blueComponent)
    }

    /// WCAG contrast ratio between two colours (1...21).
    static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let hi = max(relativeLuminance(a), relativeLuminance(b))
        let lo = min(relativeLuminance(a), relativeLuminance(b))
        return (hi + 0.05) / (lo + 0.05)
    }
}

/// Everything a sidebar row shows; derived by the window controller.
/// Rows carry their own theme — sessions theme independently, so each
/// row renders in its session's phosphor.
struct SessionRowModel: Equatable {
    var id: UUID
    var index: Int       // 1-based; ⌘index jumps here
    var title: String
    var metaLine: String
    var isActive: Bool
    var isRunning: Bool
    var dirtyCount: Int?
    /// Bells unseen since the tab was last viewed; nil hides the badge.
    var attentionCount: Int? = nil
    /// OSC 9;4 task progress; nil hides the bar.
    var progress: ProgressReport? = nil
    var theme: SidebarTheme
}

/// Everything the hover card shows. Git fields arrive async.
struct SessionCardModel: Equatable {
    var title: String
    var index: Int
    var isRunning: Bool
    var statusText: String
    var path: String
    var branchLine: String?  // nil = probing, "" = not a repo
    var branchIsDirty: Bool
    var statusLine: String
    var processLine: String
    var exitLine: String?
    /// "rang 2m ago" while the session has unseen bells.
    var bellLine: String? = nil
}

private let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

extension NSPasteboard.PasteboardType {
    /// A sidebar session row drag: the payload is the SessionTab UUID.
    static let crtSessionRow = NSPasteboard.PasteboardType("mbcltd.crterminal.session-row")
}

final class SessionSidebarView: NSView {
    static let width: CGFloat = 240

    var onSelect: ((Int) -> Void)?
    /// The row's hover ✕: close the session at this index.
    var onClose: ((Int) -> Void)?
    var onNewSession: (() -> Void)?
    /// Hover changed: row index (into the models array) or nil, plus the
    /// row's frame in the sidebar's coordinates for card placement.
    var onHover: ((Int?, NSRect) -> Void)?
    /// A row drop landed here (from this window's sidebar or another's):
    /// move the session to the gap index. Returns whether it was accepted.
    var onDropSession: ((UUID, Int) -> Bool)?
    /// A row drag ended with no drop target anywhere — the tear-off case.
    var onDragEndedWithoutDrop: ((UUID, NSPoint) -> Void)?

    private(set) var theme: SidebarTheme
    private var rowViews: [SessionRowView] = []
    /// Insertion gap (0...count) the current drag would drop into. The
    /// indicator is drawn by `rowContainer` so it scrolls with the rows.
    private var dropGap: Int? {
        didSet {
            guard dropGap != oldValue else { return }
            rowContainer.dropGap = dropGap
        }
    }
    private var draggedSessionID: UUID?
    private let headerHeight: CGFloat = 42
    private let footerHeight: CGFloat = 44
    private let rowHeight: CGFloat = 50
    private let rowGap: CGFloat = 3
    /// Inset of the first row below the scroll area's top edge.
    private let rowTopInset: CGFloat = 4
    private let plusButton = SidebarGlyphButton(glyph: "+", size: 17)
    private let footer = SidebarFooterView()
    private var sessionCount = 0
    /// Rows live in a scroll view so a long session list scrolls rather than
    /// running off the bottom behind the footer (issue #21). The scroll view
    /// is transparent: the sidebar paints the background and right border
    /// behind it, and rows show those through their gaps.
    private let scrollView = NSScrollView()
    private let rowContainer = RowContainerView()
    private var scrollObserver: NSObjectProtocol?
    /// How close (in points) the drag must get to the scroll area's top or
    /// bottom edge before the list starts auto-scrolling.
    private let autoscrollMargin: CGFloat = 28
    private var autoscrollTimer: Timer?
    /// Latest drag location in sidebar coordinates, so the autoscroll timer
    /// keeps scrolling while the cursor holds still in a hot zone.
    private var lastDragLocation: NSPoint?

    override var isFlipped: Bool { true }

    init(theme: SidebarTheme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 600))
        plusButton.onClick = { [weak self] in self?.onNewSession?() }
        addSubview(plusButton)
        rowContainer.rowHeight = rowHeight
        rowContainer.rowGap = rowGap
        rowContainer.topInset = rowTopInset
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = rowContainer
        // Re-evaluate hover as rows scroll under a still cursor (tracking
        // areas only fire on cursor movement, not on content movement).
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizeHoverWithMouse() }
        }
        addSubview(scrollView)
        footer.onClick = { [weak self] in self?.onNewSession?() }
        addSubview(footer)
        registerForDraggedTypes([.crtSessionRow])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SessionSidebarView is created in code")
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        autoscrollTimer?.invalidate()
    }

    func apply(theme: SidebarTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        applyTheme()
    }

    private func applyTheme() {
        plusButton.theme = theme
        footer.theme = theme
        rowContainer.accent = theme.accent
        rowContainer.background = theme.background
        needsDisplay = true
    }

    /// Reconciles row views against the models (rows are stateful: pulse
    /// animation + tracking areas survive metadata refreshes).
    func update(rows models: [SessionRowModel]) {
        sessionCount = models.count
        while rowViews.count > models.count {
            rowViews.removeLast().removeFromSuperview()
        }
        while rowViews.count < models.count {
            let row = SessionRowView()
            row.onClick = { [weak self, weak row] in
                guard let self, let row,
                      let index = self.rowViews.firstIndex(of: row) else { return }
                self.onSelect?(index)
            }
            row.onClose = { [weak self, weak row] in
                guard let self, let row,
                      let index = self.rowViews.firstIndex(of: row) else { return }
                self.onClose?(index)
            }
            row.onHoverChange = { [weak self, weak row] hovering in
                guard let self, let row,
                      let index = self.rowViews.firstIndex(of: row) else { return }
                // Report the row's frame in sidebar coordinates (it lives in
                // the scrolled document view) for hover-card placement.
                let frame = self.convert(row.frame, from: self.rowContainer)
                self.onHover?(hovering ? index : nil, frame)
            }
            row.onDragStart = { [weak self, weak row] event in
                guard let self, let row else { return }
                self.beginRowDrag(row, with: event)
            }
            rowViews.append(row)
            rowContainer.addSubview(row)
        }
        for (view, model) in zip(rowViews, models) {
            view.model = model
        }
        needsLayout = true
        needsDisplay = true
    }

    /// The row's on-screen frame in the sidebar's coordinates (rows live in
    /// the scrolled document view; callers — hover-card placement, the drop
    /// math, the tests — work in sidebar space).
    func frameForRow(at index: Int) -> NSRect {
        guard rowViews.indices.contains(index) else { return .zero }
        return convert(rowViews[index].frame, from: rowContainer)
    }

    /// Whether the session list is taller than its visible area — i.e. the
    /// scroll bar is in play. Test/diagnostic hook.
    var rowsOverflow: Bool {
        rowContainer.frame.height > scrollView.contentView.bounds.height
    }

    /// Scrolls the list so the row at `index` is fully visible, with a little
    /// margin. Called when a session is activated (⌘K jump, next/prev) so the
    /// scroll follows focus.
    func scrollRowIntoView(at index: Int) {
        guard rowViews.indices.contains(index) else { return }
        layoutSubtreeIfNeeded()
        rowContainer.scrollToVisible(
            rowViews[index].frame.insetBy(dx: 0, dy: -rowGap))
    }

    /// Sets exactly the row under the pointer hovered (or none), correcting
    /// the stale-highlight that scrolling leaves when the cursor doesn't move.
    private func synchronizeHoverWithMouse() {
        // A drag is over the sidebar (drop indicator showing): don't revive
        // hover highlights or the hover card mid-drag.
        guard dropGap == nil, let window else { return }
        let inWindow = window.mouseLocationOutsideOfEventStream
        let overRows = scrollView.frame.contains(convert(inWindow, from: nil))
        let inContainer = rowContainer.convert(inWindow, from: nil)
        for row in rowViews {
            row.setHovered(overRows && row.frame.contains(inContainer))
        }
    }

    /// Scrolls the session list by the given offset (clamped by the scroll
    /// view). Test/diagnostic hook for the scrolled drop-gap math.
    func scrollRows(toOffset y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Row dragging (reorder / move between windows / tear off)

    /// Maps a point in sidebar coordinates to the insertion gap between
    /// rows (0 = before the first row, count = after the last). Accounts for
    /// the scroll offset so the gap tracks the rows the user actually sees.
    func dropGapIndex(at point: NSPoint) -> Int {
        let slot = rowHeight + rowGap
        // Into document coordinates: undo the scroll area's top edge, add how
        // far the rows are scrolled.
        let documentY = point.y - scrollView.frame.minY + scrollView.contentView.bounds.origin.y
        let raw = Int(((documentY - rowTopInset) / slot).rounded())
        return min(max(0, raw), sessionCount)
    }

    /// Rows report the gesture; the sidebar runs the dragging session so
    /// one place owns the pasteboard and the end-of-drag bookkeeping.
    private func beginRowDrag(_ row: SessionRowView, with event: NSEvent) {
        guard let id = row.model?.id else { return }
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: .crtSessionRow)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        // The session is begun on the sidebar, so the image frame is in
        // sidebar coordinates — convert it up from the scrolled document.
        dragItem.setDraggingFrame(
            convert(row.frame, from: rowContainer), contents: row.dragImage())
        draggedSessionID = id
        onHover?(nil, .zero)  // no hover card while dragging
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        // A drag released outside every window tears the session off into
        // a new window — snapping the image back would contradict that.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    private func dragUpdate(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [.crtSessionRow]) != nil
        else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        lastDragLocation = point
        dropGap = dropGapIndex(at: point)
        updateAutoscroll()
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragUpdate(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragUpdate(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropGap = nil
        endAutoscroll()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropGap = nil
        endAutoscroll()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropGap = nil; endAutoscroll() }
        guard let string = sender.draggingPasteboard.string(forType: .crtSessionRow),
              let id = UUID(uuidString: string) else { return false }
        let gap = dropGapIndex(at: convert(sender.draggingLocation, from: nil))
        return onDropSession?(id, gap) ?? false
    }

    // MARK: Drag autoscroll

    /// Starts/stops the autoscroll timer based on the latest drag location.
    /// The timer runs in `.common` mode so it keeps firing during the drag's
    /// event-tracking run loop, scrolling even while the cursor holds still.
    private func updateAutoscroll() {
        guard autoscrollVelocity() != 0 else { return endAutoscroll() }
        guard autoscrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepAutoscroll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscrollTimer = timer
    }

    private func endAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        lastDragLocation = nil
    }

    private func autoscrollVelocity() -> CGFloat {
        guard let point = lastDragLocation else { return 0 }
        return autoscrollVelocity(for: point)
    }

    /// Points to scroll per tick for a drag at `point` (sidebar coordinates):
    /// negative (up) near the top edge, positive (down) near the bottom, 0
    /// outside both hot zones or when nothing overflows. Ramps up as the
    /// cursor nears the edge.
    func autoscrollVelocity(for point: NSPoint) -> CGFloat {
        guard rowsOverflow else { return 0 }
        let fromTop = point.y - scrollView.frame.minY
        let fromBottom = scrollView.frame.maxY - point.y
        if fromTop < autoscrollMargin {
            return -max(3, (autoscrollMargin - fromTop) / 2)
        }
        if fromBottom < autoscrollMargin {
            return max(3, (autoscrollMargin - fromBottom) / 2)
        }
        return 0
    }

    private func stepAutoscroll() {
        let velocity = autoscrollVelocity()
        guard velocity != 0, let point = lastDragLocation else { return endAutoscroll() }
        let clip = scrollView.contentView
        let maxOffset = max(0, rowContainer.frame.height - clip.bounds.height)
        let newY = min(max(0, clip.bounds.origin.y + velocity), maxOffset)
        guard newY != clip.bounds.origin.y else { return }  // at an end
        clip.scroll(to: NSPoint(x: 0, y: newY))
        scrollView.reflectScrolledClipView(clip)
        // The cursor hasn't moved but different rows are under it now.
        dropGap = dropGapIndex(at: point)
    }

    override func layout() {
        super.layout()
        plusButton.frame = NSRect(
            x: bounds.width - 10 - 24, y: (headerHeight - 24) / 2, width: 24, height: 24)
        // 1px short of the right edge so the sidebar's border stays visible.
        scrollView.frame = NSRect(
            x: 0, y: headerHeight, width: max(0, bounds.width - 1),
            height: max(0, bounds.height - headerHeight - footerHeight))
        layoutRows()
        footer.frame = NSRect(
            x: 0, y: bounds.height - footerHeight,
            width: bounds.width, height: footerHeight)
    }

    /// Positions the rows inside the scrolling document view and sizes the
    /// document to their full height so the scroll bar appears once the list
    /// outgrows the visible area.
    private func layoutRows() {
        let slot = rowHeight + rowGap
        let width = scrollView.frame.width
        let contentHeight = rowTopInset + CGFloat(rowViews.count) * slot
        rowContainer.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        var y = rowTopInset
        for row in rowViews {
            row.frame = NSRect(x: 8, y: y, width: width - 16, height: rowHeight)
            y += slot
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.background.setFill()
        bounds.fill()
        // Right border.
        theme.separator.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()

        ("SESSIONS" as NSString).draw(
            at: NSPoint(x: 16, y: (headerHeight - 13) / 2),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .kern: 1.0,
                .foregroundColor: theme.faint,
            ])
        let count = "\(sessionCount)" as NSString
        let countAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: theme.faint,
        ]
        let countSize = count.size(withAttributes: countAttrs)
        count.draw(
            at: NSPoint(
                x: plusButton.frame.minX - 8 - countSize.width,
                y: (headerHeight - countSize.height) / 2),
            withAttributes: countAttrs)
    }
}

/// The scrolling document view that hosts the session rows. It paints the
/// sidebar background itself — a transparent document view would leave stale
/// pixels in the row gaps as the clip view scrolls — and draws the row-drag
/// insertion indicator, both in its own (scrolled) coordinates. It stops 1px
/// short of the sidebar's right edge so the sidebar's border shows beside it.
final class RowContainerView: NSView {
    var rowHeight: CGFloat = 50
    var rowGap: CGFloat = 3
    var topInset: CGFloat = 4
    var accent: NSColor = .clear
    var background: NSColor = .clear { didSet { needsDisplay = true } }
    /// Insertion gap (0...count) the current drag would drop into.
    var dropGap: Int? {
        didSet { if dropGap != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.fill()
        guard let dropGap else { return }
        let y = topInset + CGFloat(dropGap) * (rowHeight + rowGap) - 2.5
        accent.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 8, y: y, width: bounds.width - 16, height: 3),
            xRadius: 1.5, yRadius: 1.5
        ).fill()
    }
}

extension SessionSidebarView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // .move outside the app too, so a tear-off drop over the desktop
        // doesn't show the forbidden cursor.
        .move
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        dropGap = nil
        endAutoscroll()
        guard let id = draggedSessionID else { return }
        draggedSessionID = nil
        if operation.isEmpty {
            onDragEndedWithoutDrop?(id, screenPoint)
        }
    }
}

/// One session row: accent bar, icon chip, title + pulse, meta line,
/// badge — all drawn in the row's own session theme.
final class SessionRowView: NSView {
    var model: SessionRowModel? {
        didSet { if model != oldValue { modelDidChange(from: oldValue) } }
    }
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    /// Fired once when a press turns into a drag (passes the drag event).
    var onDragStart: ((NSEvent) -> Void)?

    private var isHovered = false
    private var isCloseHovered = false
    private var mouseDownLocation: NSPoint?
    private let pulseDot = CALayer()
    /// Amber attention dot, pulsing until the session is viewed.
    private let bellDot = CALayer()
    var showsBellBadge: Bool { !bellDot.isHidden }
    /// Thin task-progress bar hugging the row's bottom edge.
    private let progressTrack = CALayer()
    private let progressFill = CALayer()
    /// Fill fraction while the bar shows (nil = hidden); for tests.
    var progressBarFraction: CGFloat? {
        progressTrack.isHidden || progressTrack.frame.width == 0
            ? nil : progressFill.frame.width / progressTrack.frame.width
    }

    /// The hover-only ✕ pinned to the right edge.
    private var closeRect: NSRect {
        NSRect(x: bounds.width - 10 - 16, y: bounds.midY - 8, width: 16, height: 16)
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        pulseDot.frame = CGRect(x: 0, y: 0, width: 6, height: 6)
        pulseDot.cornerRadius = 3
        pulseDot.isHidden = true
        layer?.addSublayer(pulseDot)
        bellDot.frame = CGRect(x: 0, y: 0, width: 7, height: 7)
        bellDot.cornerRadius = 3.5
        bellDot.isHidden = true
        layer?.addSublayer(bellDot)
        for bar in [progressTrack, progressFill] {
            bar.cornerRadius = 1
            bar.isHidden = true
            layer?.addSublayer(bar)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SessionRowView is created in code")
    }

    private func modelDidChange(from old: SessionRowModel?) {
        guard let model else { return }
        let theme = model.theme
        setAccessibilityTitle(model.title)
        pulseDot.backgroundColor = theme.green.cgColor
        if model.isRunning != (old?.isRunning ?? false) {
            pulseDot.isHidden = !model.isRunning
            if model.isRunning {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.35
                pulse.duration = 0.75
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulseDot.add(pulse, forKey: "pulse")
            } else {
                pulseDot.removeAnimation(forKey: "pulse")
            }
        }
        bellDot.backgroundColor = theme.amber.cgColor
        let hasBells = (model.attentionCount ?? 0) > 0
        if hasBells != ((old?.attentionCount ?? 0) > 0) {
            bellDot.isHidden = !hasBells
            if hasBells {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.35
                pulse.duration = 0.75
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                bellDot.add(pulse, forKey: "pulse")
            } else {
                bellDot.removeAnimation(forKey: "pulse")
            }
        }
        let progress = model.progress
        progressTrack.isHidden = progress == nil
        progressFill.isHidden = progress == nil
        progressTrack.backgroundColor = theme.separator.cgColor
        let fillColor: NSColor
        switch progress?.state {
        case .error?: fillColor = theme.amber
        case .paused?: fillColor = theme.dim
        default: fillColor = theme.accent
        }
        progressFill.backgroundColor = fillColor.cgColor
        // Indeterminate has no meaningful fill: span the track and shimmer.
        let indeterminate = progress?.state == .indeterminate
        if indeterminate != (old?.progress?.state == .indeterminate) {
            if indeterminate {
                let shimmer = CABasicAnimation(keyPath: "opacity")
                shimmer.fromValue = 0.25
                shimmer.toValue = 0.7
                shimmer.duration = 0.6
                shimmer.autoreverses = true
                shimmer.repeatCount = .infinity
                progressFill.add(shimmer, forKey: "shimmer")
            } else {
                progressFill.removeAnimation(forKey: "shimmer")
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let progress = model?.progress else { return }
        let track = CGRect(
            x: 12, y: bounds.height - 5, width: bounds.width - 24, height: 2)
        progressTrack.frame = track
        let fraction = progress.state == .indeterminate
            ? 1.0 : CGFloat(progress.percent) / 100
        progressFill.frame = CGRect(
            x: track.minX, y: track.minY, width: track.width * fraction, height: 2)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // mouseMoved keeps the ✕'s own hover highlight live inside the row.
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    /// Drives the hover state from outside the tracking area — the sidebar
    /// re-syncs hover after a scroll, since tracking areas don't fire
    /// enter/exit when content moves under a stationary cursor.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        if !hovered { isCloseHovered = false }
        needsDisplay = true
        onHoverChange?(hovered)
    }

    override func mouseMoved(with event: NSEvent) {
        let inClose = closeRect.contains(convert(event.locationInWindow, from: nil))
        if inClose != isCloseHovered {
            isCloseHovered = inClose
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        // A small threshold keeps sloppy clicks from becoming drags. Once a
        // dragging session starts, AppKit swallows the matching mouseUp, so
        // the row won't also select.
        guard let start = mouseDownLocation else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        mouseDownLocation = nil
        onDragStart?(event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if isHovered && closeRect.contains(point) {
            onClose?()
        } else {
            onClick?()
        }
    }

    /// A bitmap of the row as currently drawn, for the drag image.
    func dragImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let theme = model.theme
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        if model.isActive {
            theme.chip.setFill()
            path.fill()
            theme.separator.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if isHovered {
            theme.accent.withAlphaComponent(0.05).setFill()
            path.fill()
        }

        // Active accent bar hugging the left edge.
        if model.isActive {
            theme.accent.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: 12, width: 3, height: bounds.height - 24),
                xRadius: 1.5, yRadius: 1.5
            ).fill()
        }

        // Icon chip.
        let chipRect = NSRect(x: 10, y: bounds.midY - 14, width: 28, height: 28)
        theme.chip.setFill()
        NSBezierPath(roundedRect: chipRect, xRadius: 8, yRadius: 8).fill()
        let glyphAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: theme.accent,
        ]
        let glyph = "❯" as NSString
        let glyphSize = glyph.size(withAttributes: glyphAttrs)
        glyph.draw(
            at: NSPoint(
                x: chipRect.midX - glyphSize.width / 2,
                y: chipRect.midY - glyphSize.height / 2),
            withAttributes: glyphAttrs)

        let textX = chipRect.maxX + 10
        var textRight = bounds.width - 10

        // Hover-only close widget; the badge and title shuffle left of it.
        if isHovered {
            let close = closeRect
            if isCloseHovered {
                theme.chip.setFill()
                NSBezierPath(roundedRect: close, xRadius: 5, yRadius: 5).fill()
            }
            let crossAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: isCloseHovered ? theme.text : theme.dim,
            ]
            let cross = "✕" as NSString
            let crossSize = cross.size(withAttributes: crossAttrs)
            cross.draw(
                at: NSPoint(
                    x: close.midX - crossSize.width / 2,
                    y: close.midY - crossSize.height / 2),
                withAttributes: crossAttrs)
            textRight = close.minX - 6
        }

        // Bell badge: an amber dot (plus a count past one bell), pinned
        // rightmost — attention outranks the git badge.
        if let bells = model.attentionCount, bells > 0 {
            bellDot.position = CGPoint(x: textRight - 9, y: bounds.midY)
            textRight -= 18
            if bells > 1 {
                let count = "\(bells)" as NSString
                let countAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: theme.amber,
                ]
                let size = count.size(withAttributes: countAttrs)
                count.draw(
                    at: NSPoint(
                        x: textRight - size.width, y: bounds.midY - size.height / 2),
                    withAttributes: countAttrs)
                textRight -= size.width + 6
            }
        }

        // Dirty badge pinned right.
        if let dirty = model.dirtyCount, dirty > 0 {
            let badge = "+\(dirty)" as NSString
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: theme.amber,
            ]
            let badgeSize = badge.size(withAttributes: badgeAttrs)
            let badgeRect = NSRect(
                x: textRight - badgeSize.width - 12, y: bounds.midY - 8,
                width: badgeSize.width + 12, height: 16)
            theme.chip.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 8, yRadius: 8).fill()
            badge.draw(
                at: NSPoint(x: badgeRect.minX + 6, y: badgeRect.midY - badgeSize.height / 2),
                withAttributes: badgeAttrs)
            textRight = badgeRect.minX - 6
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: model.isActive ? theme.text : theme.dim,
            .paragraphStyle: paragraph,
        ]
        var titleWidth = textRight - textX
        if model.isRunning { titleWidth -= 12 }  // room for the pulse dot
        let titleRect = NSRect(x: textX, y: 8, width: titleWidth, height: 16)
        (model.title as NSString).draw(in: titleRect, withAttributes: titleAttrs)

        if model.isRunning {
            let drawn = min(
                (model.title as NSString).size(withAttributes: titleAttrs).width,
                titleWidth)
            pulseDot.position = CGPoint(x: textX + drawn + 9, y: titleRect.midY)
        }

        (model.metaLine as NSString).draw(
            in: NSRect(x: textX, y: 26, width: textRight - textX, height: 14),
            withAttributes: [
                .font: monoFont,
                .foregroundColor: theme.faint,
                .paragraphStyle: paragraph,
            ])
    }
}

/// The hover detail card: status pill, path/branch/status/process rows,
/// and the focus/jump hints. Sized to fit its rows.
final class SessionHoverCard: NSView {
    static let width: CGFloat = 272

    private var theme: SidebarTheme
    private var model: SessionCardModel?

    override var isFlipped: Bool { true }

    init(theme: SidebarTheme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.borderWidth = 1
        shadow = {
            let s = NSShadow()
            s.shadowOffset = NSSize(width: 0, height: -8)
            s.shadowBlurRadius = 24
            s.shadowColor = NSColor.black.withAlphaComponent(0.5)
            return s
        }()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SessionHoverCard is created in code")
    }

    /// Purely informational, like the design's pointer-events: none — the
    /// card must never swallow clicks meant for the terminal beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private struct Line {
        var key: String
        var value: String
        var color: NSColor
        var mono: Bool
    }

    private func lines() -> [Line] {
        guard let model else { return [] }
        var lines = [
            Line(key: "PATH", value: model.path, color: theme.accent, mono: true)
        ]
        let branch: Line
        if let branchLine = model.branchLine {
            branch = branchLine.isEmpty
                ? Line(key: "BRANCH", value: "not a repo", color: theme.faint, mono: false)
                : Line(
                    key: "BRANCH", value: branchLine,
                    color: model.branchIsDirty ? theme.amber : theme.green, mono: false)
        } else {
            branch = Line(key: "BRANCH", value: "…", color: theme.faint, mono: false)
        }
        lines.append(branch)
        lines.append(Line(
            key: "STATUS", value: model.statusLine,
            color: model.isRunning ? theme.green : theme.dim, mono: false))
        if let exitLine = model.exitLine {
            lines.append(Line(
                key: "EXIT", value: exitLine,
                color: exitLine.hasPrefix("✓") ? theme.green : theme.amber, mono: false))
        }
        if let bellLine = model.bellLine {
            lines.append(Line(key: "BELL", value: bellLine, color: theme.amber, mono: false))
        }
        lines.append(Line(
            key: "PROCESS", value: model.processLine, color: theme.dim, mono: true))
        return lines
    }

    /// Returns the card's fitting height for the current model.
    func update(model: SessionCardModel, theme: SidebarTheme) -> CGFloat {
        self.model = model
        self.theme = theme
        layer?.backgroundColor = theme.cardBackground.cgColor
        layer?.borderColor = theme.cardBorder.cgColor
        needsDisplay = true
        // header 28 + divider section 23 + rows + hint footer 32 + padding.
        let rows = CGFloat(lines().count)
        return 14 + 28 + 22 + rows * 19 + 32 + 12
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let inset: CGFloat = 15
        var y: CGFloat = 14

        // Header: icon chip, title, status pill.
        let chipRect = NSRect(x: inset, y: y, width: 28, height: 28)
        theme.chip.setFill()
        NSBezierPath(roundedRect: chipRect, xRadius: 8, yRadius: 8).fill()
        let glyphAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold),
            .foregroundColor: theme.accent,
        ]
        let glyph = "❯" as NSString
        let glyphSize = glyph.size(withAttributes: glyphAttrs)
        glyph.draw(
            at: NSPoint(
                x: chipRect.midX - glyphSize.width / 2,
                y: chipRect.midY - glyphSize.height / 2),
            withAttributes: glyphAttrs)

        let pillText = model.statusText as NSString
        let pillAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: model.isRunning ? theme.green : theme.dim,
        ]
        let pillTextSize = pillText.size(withAttributes: pillAttrs)
        let pillRect = NSRect(
            x: bounds.width - inset - pillTextSize.width - 18,
            y: chipRect.midY - 9.5, width: pillTextSize.width + 18, height: 19)
        theme.chip.setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: 9.5, yRadius: 9.5).fill()
        pillText.draw(
            at: NSPoint(x: pillRect.minX + 9, y: pillRect.midY - pillTextSize.height / 2),
            withAttributes: pillAttrs)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (model.title as NSString).draw(
            in: NSRect(
                x: chipRect.maxX + 10, y: chipRect.midY - 8,
                width: pillRect.minX - chipRect.maxX - 18, height: 17),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: theme.text,
                .paragraphStyle: paragraph,
            ])
        y = chipRect.maxY + 11

        theme.separator.setFill()
        NSRect(x: inset, y: y, width: bounds.width - inset * 2, height: 1).fill()
        y += 11

        for line in lines() {
            (line.key as NSString).draw(
                at: NSPoint(x: inset, y: y + 1.5),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                    .kern: 0.5,
                    .foregroundColor: theme.faint,
                ])
            let valueX = inset + 64
            (line.value as NSString).draw(
                in: NSRect(x: valueX, y: y, width: bounds.width - inset - valueX, height: 16),
                withAttributes: [
                    .font: line.mono
                        ? monoFont : NSFont.systemFont(ofSize: 11.5),
                    .foregroundColor: line.color,
                    .paragraphStyle: paragraph,
                ])
            y += 19
        }

        y += 10
        theme.separator.setFill()
        NSRect(x: inset, y: y, width: bounds.width - inset * 2, height: 1).fill()
        y += 8
        let hints = NSMutableAttributedString()
        hints.append(NSAttributedString(string: "↵", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: theme.dim,
        ]))
        hints.append(NSAttributedString(string: " focus   ", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: theme.faint,
        ]))
        hints.append(NSAttributedString(string: "⌘\(model.index)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: theme.dim,
        ]))
        hints.append(NSAttributedString(string: " jump", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: theme.faint,
        ]))
        hints.draw(at: NSPoint(x: inset, y: y))
    }
}

/// Small hover-highlighted glyph button (the sidebar's header "+").
final class SidebarGlyphButton: NSView {
    var onClick: (() -> Void)?
    var theme: SidebarTheme? {
        didSet { needsDisplay = true }
    }
    private let glyph: String
    private let size: CGFloat
    private var isHovered = false

    init(glyph: String, size: CGFloat) {
        self.glyph = glyph
        self.size = size
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarGlyphButton is created in code")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installHoverTracking()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        if isHovered {
            theme.chip.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .light),
            .foregroundColor: theme.dim,
        ]
        let text = glyph as NSString
        let textSize = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(
                x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2),
            withAttributes: attrs)
    }
}

/// "+ New session  ⌘T" footer row.
final class SidebarFooterView: NSView {
    var onClick: (() -> Void)?
    var theme: SidebarTheme? {
        didSet { needsDisplay = true }
    }
    private var isHovered = false

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installHoverTracking()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        if isHovered {
            theme.chip.setFill()
            bounds.fill()
        }
        theme.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let plus = "+" as NSString
        let plusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .light),
            .foregroundColor: theme.dim,
        ]
        let plusSize = plus.size(withAttributes: plusAttrs)
        plus.draw(
            at: NSPoint(x: 16, y: bounds.midY - plusSize.height / 2),
            withAttributes: plusAttrs)
        ("New session" as NSString).draw(
            at: NSPoint(x: 16 + plusSize.width + 9, y: bounds.midY - 8),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: theme.dim,
            ])
        let kbd = "⌘T" as NSString
        let kbdAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: theme.faint,
        ]
        let kbdSize = kbd.size(withAttributes: kbdAttrs)
        kbd.draw(
            at: NSPoint(x: bounds.width - 16 - kbdSize.width, y: bounds.midY - kbdSize.height / 2),
            withAttributes: kbdAttrs)
    }
}

extension NSView {
    /// Shared tracking-area refresh for the sidebar's hover views.
    fileprivate func installHoverTracking() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self))
    }
}
