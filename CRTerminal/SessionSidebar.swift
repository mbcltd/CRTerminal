import AppKit
import CRTRendering

// The vertical session sidebar from the GlassTerm design handoff: rich
// rows (accent bar, icon chip, running pulse, metadata line) with a hover
// detail card per session. Chrome colors derive from the active preset so
// the sidebar wears the same phosphor as the tube next to it.

/// Sidebar/hover-card palette derived from a CRT preset.
struct SidebarTheme: Equatable {
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

    init(preset: CRTPreset) {
        let phosphor = preset.effects
            ? NSColor(preset.phosphor.color)
            : NSColor(srgbRed: 0.91, green: 0.92, blue: 0.96, alpha: 1)
        accent = phosphor
        // Monochrome tubes have exactly one color; color tubes and museum
        // mode get conventional status colors.
        let monochrome = preset.effects && preset.phosphor.monochrome
        green = monochrome ? phosphor : .systemGreen
        amber = monochrome ? phosphor : NSColor(srgbRed: 0.88, green: 0.69, blue: 0.41, alpha: 1)
        text = phosphor.blended(withFraction: preset.effects ? 0.15 : 0, of: .white) ?? phosphor
        dim = phosphor.withAlphaComponent(0.62)
        faint = phosphor.withAlphaComponent(0.34)
        chip = phosphor.withAlphaComponent(0.09)
        separator = phosphor.withAlphaComponent(0.16)
        background = NSColor(srgbRed: 0.02, green: 0.03, blue: 0.02, alpha: 1)
            .blended(withFraction: 0.06, of: phosphor) ?? .black
        cardBackground = NSColor(srgbRed: 0.04, green: 0.055, blue: 0.045, alpha: 0.97)
            .blended(withFraction: 0.05, of: phosphor) ?? .black
        cardBorder = phosphor.withAlphaComponent(0.3)
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
    /// Insertion gap (0...count) the current drag would drop into.
    private var dropGap: Int? {
        didSet { if dropGap != oldValue { needsDisplay = true } }
    }
    private var draggedSessionID: UUID?
    private let headerHeight: CGFloat = 42
    private let footerHeight: CGFloat = 44
    private let rowHeight: CGFloat = 50
    private let plusButton = SidebarGlyphButton(glyph: "+", size: 17)
    private let footer = SidebarFooterView()
    private var sessionCount = 0

    override var isFlipped: Bool { true }

    init(theme: SidebarTheme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 600))
        plusButton.onClick = { [weak self] in self?.onNewSession?() }
        addSubview(plusButton)
        footer.onClick = { [weak self] in self?.onNewSession?() }
        addSubview(footer)
        registerForDraggedTypes([.crtSessionRow])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SessionSidebarView is created in code")
    }

    func apply(theme: SidebarTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        applyTheme()
    }

    private func applyTheme() {
        plusButton.theme = theme
        footer.theme = theme
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
                self.onHover?(hovering ? index : nil, row.frame)
            }
            row.onDragStart = { [weak self, weak row] event in
                guard let self, let row else { return }
                self.beginRowDrag(row, with: event)
            }
            rowViews.append(row)
            addSubview(row)
        }
        for (view, model) in zip(rowViews, models) {
            view.model = model
        }
        needsLayout = true
        needsDisplay = true
    }

    func frameForRow(at index: Int) -> NSRect {
        rowViews.indices.contains(index) ? rowViews[index].frame : .zero
    }

    // MARK: Row dragging (reorder / move between windows / tear off)

    /// Maps a point in sidebar coordinates to the insertion gap between
    /// rows (0 = before the first row, count = after the last).
    func dropGapIndex(at point: NSPoint) -> Int {
        let slot = rowHeight + 3
        let raw = Int(((point.y - (headerHeight + 4)) / slot).rounded())
        return min(max(0, raw), sessionCount)
    }

    /// Rows report the gesture; the sidebar runs the dragging session so
    /// one place owns the pasteboard and the end-of-drag bookkeeping.
    private func beginRowDrag(_ row: SessionRowView, with event: NSEvent) {
        guard let id = row.model?.id else { return }
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: .crtSessionRow)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(row.frame, contents: row.dragImage())
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
        dropGap = dropGapIndex(at: convert(sender.draggingLocation, from: nil))
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
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropGap = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropGap = nil }
        guard let string = sender.draggingPasteboard.string(forType: .crtSessionRow),
              let id = UUID(uuidString: string) else { return false }
        let gap = dropGapIndex(at: convert(sender.draggingLocation, from: nil))
        return onDropSession?(id, gap) ?? false
    }

    override func layout() {
        super.layout()
        plusButton.frame = NSRect(
            x: bounds.width - 10 - 24, y: (headerHeight - 24) / 2, width: 24, height: 24)
        var y = headerHeight + 4
        for row in rowViews {
            row.frame = NSRect(x: 8, y: y, width: bounds.width - 16, height: rowHeight)
            y += rowHeight + 3
        }
        footer.frame = NSRect(
            x: 0, y: bounds.height - footerHeight,
            width: bounds.width, height: footerHeight)
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

        // Insertion indicator in the gap a row drag would drop into.
        if let dropGap {
            let y = headerHeight + 4 + CGFloat(dropGap) * (rowHeight + 3) - 2.5
            theme.accent.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 8, y: y, width: bounds.width - 16, height: 3),
                xRadius: 1.5, yRadius: 1.5
            ).fill()
        }
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
        needsDisplay = true
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
        isHovered = true
        needsDisplay = true
        onHoverChange?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        let inClose = closeRect.contains(convert(event.locationInWindow, from: nil))
        if inClose != isCloseHovered {
            isCloseHovered = inClose
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isCloseHovered = false
        needsDisplay = true
        onHoverChange?(false)
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
