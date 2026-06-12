import AppKit
import CRTRendering

/// The titlebar's right-hand control cluster (from the GlassTerm design
/// handoff): a theme switcher button whose dropdown rows are each styled
/// by their own preset, and a skeuomorphic DEGAUSS button that only
/// appears when the active preset is actually a CRT.
final class TitlebarControlCluster: NSView {
    private let themeButton = ThemeSwitcherButton()
    private let degaussButton = DegaussButton()
    private let presets: [CRTPreset]
    private var currentPresetName: String
    var onSelectPreset: ((CRTPreset) -> Void)?

    /// Thumbnails go through the real render pipeline, like the preset
    /// gallery. Built lazily so windows that never open the menu never
    /// pay for a preview renderer.
    private lazy var preview = PresetPreviewRenderer()
    private var thumbnails: [String: NSImage] = [:]

    private static let height: CGFloat = 28
    private static let controlHeight: CGFloat = 22
    private static let gap: CGFloat = 7

    init(presets: [CRTPreset], currentPreset: CRTPreset) {
        self.presets = presets
        self.currentPresetName = currentPreset.name
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: Self.height))

        degaussButton.target = nil
        degaussButton.action = #selector(TerminalView.degauss(_:))
        addSubview(degaussButton)

        themeButton.onClick = { [weak self] in self?.showThemeMenu() }
        addSubview(themeButton)

        update(preset: currentPreset)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TitlebarControlCluster is created in code")
    }

    func update(preset: CRTPreset) {
        currentPresetName = preset.name
        themeButton.configure(
            name: preset.name, dotColor: NSColor(preset.phosphor.color))
        degaussButton.isHidden = !preset.effects || !preset.degaussButton
        relayout()
    }

    private func relayout() {
        let y = (Self.height - Self.controlHeight) / 2
        var x: CGFloat = 0
        themeButton.frame = NSRect(
            x: x, y: y, width: themeButton.fittingWidth, height: Self.controlHeight)
        x = themeButton.frame.maxX
        if !degaussButton.isHidden {
            x += Self.gap
            degaussButton.frame = NSRect(
                x: x, y: y, width: degaussButton.fittingWidth, height: Self.controlHeight)
            x = degaussButton.frame.maxX
        }
        setFrameSize(NSSize(width: x + 6, height: Self.height))
    }

    // MARK: Theme menu

    private func showThemeMenu() {
        let menu = NSMenu()
        let header = NSMenuItem()
        header.attributedTitle = NSAttributedString(
            string: "THEME",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .kern: 0.8,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        header.isEnabled = false
        menu.addItem(header)
        for preset in presets {
            let item = NSMenuItem()
            item.view = ThemeMenuRowView(
                preset: preset,
                thumbnail: thumbnail(for: preset),
                isActive: preset.name == currentPresetName,
                onSelect: { [weak self] in self?.onSelectPreset?(preset) })
            menu.addItem(item)
        }
        let origin = NSPoint(
            x: themeButton.frame.minX, y: themeButton.frame.minY - 4)
        menu.popUp(positioning: nil, at: origin, in: self)
    }

    private func thumbnail(for preset: CRTPreset) -> NSImage? {
        if let cached = thumbnails[preset.name] { return cached }
        guard let cgImage = preview.image(for: preset, time: 0.4) else { return nil }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
        thumbnails[preset.name] = image
        return image
    }
}

extension NSColor {
    convenience init(_ hex: HexColor) {
        self.init(
            srgbRed: CGFloat(hex.red) / 255,
            green: CGFloat(hex.green) / 255,
            blue: CGFloat(hex.blue) / 255,
            alpha: 1)
    }
}

/// Single-button theme switcher: a phosphor-colored dot, the preset name,
/// and a chevron, in a rounded chip that adapts to the titlebar appearance.
final class ThemeSwitcherButton: NSView {
    var onClick: (() -> Void)?
    private var name = ""
    private var dotColor = NSColor.systemGreen
    private var isHovered = false { didSet { needsDisplay = true } }

    private static let nameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    var fittingWidth: CGFloat {
        let textWidth = (name as NSString)
            .size(withAttributes: [.font: Self.nameFont]).width
        // leading pad + dot + gap + name + gap + chevron + trailing pad
        return 10 + 9 + 7 + ceil(textWidth) + 6 + 7 + 10
    }

    init() {
        super.init(frame: .zero)
        toolTip = "Switch theme"
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ThemeSwitcherButton is created in code")
    }

    func configure(name: String, dotColor: NSColor) {
        self.name = name
        self.dotColor = dotColor
        setAccessibilityTitle("Theme: \(name)")
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let chip = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        NSColor.labelColor.withAlphaComponent(isHovered ? 0.12 : 0.07).setFill()
        chip.fill()
        NSColor.labelColor.withAlphaComponent(0.14).setStroke()
        chip.lineWidth = 1
        chip.stroke()

        // Dot in the active preset's phosphor color, with a chip-toned ring.
        let dotRect = NSRect(x: 10, y: bounds.midY - 4.5, width: 9, height: 9)
        dotColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        NSColor.labelColor.withAlphaComponent(0.2).setStroke()
        NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.5, dy: 0.5)).stroke()

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.nameFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let textSize = (name as NSString).size(withAttributes: nameAttrs)
        (name as NSString).draw(
            at: NSPoint(x: dotRect.maxX + 7, y: bounds.midY - textSize.height / 2),
            withAttributes: nameAttrs)

        let chevronAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let chevronSize = ("▼" as NSString).size(withAttributes: chevronAttrs)
        ("▼" as NSString).draw(
            at: NSPoint(
                x: bounds.maxX - 10 - chevronSize.width,
                y: bounds.midY - chevronSize.height / 2),
            withAttributes: chevronAttrs)
    }
}

/// The degauss control, styled per the design as an old-school graphite
/// front-panel button: raised bevel, engraved monospace label, and a
/// pressed-in state. It fires the same responder-chain action as the
/// View ▸ Degauss menu item.
final class DegaussButton: NSControl {
    private var isPressed = false { didSet { needsDisplay = true } }

    private static let label = "DEGAUSS"
    private static func labelAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .heavy),
            .kern: 1.4,
            .foregroundColor: color,
        ]
    }

    var fittingWidth: CGFloat {
        let textWidth = (Self.label as NSString)
            .size(withAttributes: Self.labelAttributes(color: .white)).width
        return ceil(textWidth) + 22
    }

    init() {
        super.init(frame: .zero)
        toolTip = "Degauss the tube"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityTitle("Degauss")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DegaussButton is created in code")
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        // Track until mouse-up so the press can be cancelled by dragging off.
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            isPressed = inside
            if next.type == .leftMouseUp {
                isPressed = false
                if inside, let action {
                    NSApp.sendAction(action, to: target, from: self)
                }
                break
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 1, dy: 1.5)
        let path = NSBezierPath(roundedRect: body, xRadius: 5, yRadius: 5)

        // Raised cap: drop shadow under the button, graphite gradient face.
        NSGraphicsContext.current?.saveGraphicsState()
        if !isPressed {
            let drop = NSShadow()
            drop.shadowOffset = NSSize(width: 0, height: -1.5)
            drop.shadowBlurRadius = 2
            drop.shadowColor = NSColor.black.withAlphaComponent(0.5)
            drop.set()
        }
        let face = isPressed
            ? NSGradient(colors: [
                NSColor(srgbRed: 0.13, green: 0.16, blue: 0.14, alpha: 1),
                NSColor(srgbRed: 0.17, green: 0.20, blue: 0.18, alpha: 1),
            ])
            : NSGradient(colorsAndLocations:
                (NSColor(srgbRed: 0.26, green: 0.29, blue: 0.27, alpha: 1), 0),
                (NSColor(srgbRed: 0.17, green: 0.20, blue: 0.18, alpha: 1), 0.52),
                (NSColor(srgbRed: 0.09, green: 0.11, blue: 0.09, alpha: 1), 1))
        // CSS top maps to maxY here, hence the -90° angle.
        face?.draw(in: path, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor(srgbRed: 0.05, green: 0.07, blue: 0.05, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()

        // Bevel: top highlight when raised, top inner shadow when pressed.
        let bevel = NSBezierPath(
            roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        bevel.lineWidth = 1
        if isPressed {
            NSColor.black.withAlphaComponent(0.55).setStroke()
        } else {
            NSColor.white.withAlphaComponent(0.16).setStroke()
        }
        bevel.stroke()

        // Engraved label: dark above, faint light catch below.
        let attrs = Self.labelAttributes(
            color: NSColor(srgbRed: 0.45, green: 0.51, blue: 0.48, alpha: 1))
        let size = (Self.label as NSString).size(withAttributes: attrs)
        var origin = NSPoint(
            x: body.midX - size.width / 2, y: body.midY - size.height / 2)
        if isPressed { origin.y -= 1 }
        (Self.label as NSString).draw(
            at: NSPoint(x: origin.x, y: origin.y + 1),
            withAttributes: Self.labelAttributes(
                color: NSColor.black.withAlphaComponent(0.5)))
        (Self.label as NSString).draw(
            at: NSPoint(x: origin.x, y: origin.y - 1),
            withAttributes: Self.labelAttributes(
                color: NSColor.white.withAlphaComponent(0.12)))
        (Self.label as NSString).draw(at: origin, withAttributes: attrs)
    }
}

/// One dropdown row, styled by its own preset: a live-pipeline thumbnail
/// swatch, the name in the preset's phosphor color, year + blurb, and a
/// checkmark on the active preset.
final class ThemeMenuRowView: NSView {
    private let preset: CRTPreset
    private let isActive: Bool
    private let onSelect: () -> Void
    private let thumbnail: NSImage?
    private var isHovered = false { didSet { needsDisplay = true } }

    static let size = NSSize(width: 264, height: 48)
    private static let inset: CGFloat = 5

    init(preset: CRTPreset, thumbnail: NSImage?, isActive: Bool,
         onSelect: @escaping () -> Void) {
        self.preset = preset
        self.thumbnail = thumbnail
        self.isActive = isActive
        self.onSelect = onSelect
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityTitle(preset.name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ThemeMenuRowView is created in code")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        onSelect()
    }

    private var phosphor: NSColor {
        preset.effects ? NSColor(preset.phosphor.color) : .labelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let row = bounds.insetBy(dx: Self.inset, dy: 2)
        let path = NSBezierPath(roundedRect: row, xRadius: 9, yRadius: 9)

        // Each row wears its own theme: near-black tube glass tinted with
        // the phosphor for CRT presets, the plain window tone for museum off.
        if preset.effects {
            NSColor(srgbRed: 0.04, green: 0.05, blue: 0.04, alpha: 1).setFill()
            path.fill()
            phosphor.withAlphaComponent(0.06).setFill()
            path.fill()
        } else {
            NSColor.windowBackgroundColor.setFill()
            path.fill()
        }
        if isHovered {
            NSColor.white.withAlphaComponent(preset.effects ? 0.07 : 0.4).setFill()
            path.fill()
        }
        (isActive ? phosphor : NSColor.labelColor.withAlphaComponent(0.12)).setStroke()
        path.lineWidth = 1
        path.stroke()

        // Swatch: the preset rendered through the real pipeline.
        let swatchRect = NSRect(x: row.minX + 7, y: row.midY - 16, width: 55, height: 32)
        let swatchPath = NSBezierPath(roundedRect: swatchRect, xRadius: 5, yRadius: 5)
        NSColor.black.setFill()
        swatchPath.fill()
        if let thumbnail {
            NSGraphicsContext.current?.saveGraphicsState()
            swatchPath.addClip()
            // Aspect-fill the swatch.
            let scale = max(
                swatchRect.width / thumbnail.size.width,
                swatchRect.height / thumbnail.size.height)
            let drawSize = NSSize(
                width: thumbnail.size.width * scale,
                height: thumbnail.size.height * scale)
            thumbnail.draw(
                in: NSRect(
                    x: swatchRect.midX - drawSize.width / 2,
                    y: swatchRect.midY - drawSize.height / 2,
                    width: drawSize.width, height: drawSize.height),
                from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        phosphor.withAlphaComponent(0.35).setStroke()
        swatchPath.lineWidth = 1
        swatchPath.stroke()

        let textX = swatchRect.maxX + 9
        let textWidth = row.maxX - textX - (isActive ? 24 : 10)

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: preset.effects ? phosphor : NSColor.labelColor,
        ]
        (preset.name as NSString).draw(
            in: NSRect(x: textX, y: row.midY + 1, width: textWidth, height: 16),
            withAttributes: nameAttrs)

        var detail = preset.blurb ?? ""
        if let year = preset.year { detail = "\(year) · \(detail)" }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: preset.effects
                ? phosphor.withAlphaComponent(0.55) : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        (detail as NSString).draw(
            in: NSRect(x: textX, y: row.midY - 14, width: textWidth, height: 13),
            withAttributes: detailAttrs)

        if isActive {
            let checkAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .heavy),
                .foregroundColor: phosphor,
            ]
            let size = ("✓" as NSString).size(withAttributes: checkAttrs)
            ("✓" as NSString).draw(
                at: NSPoint(x: row.maxX - 9 - size.width, y: row.midY - size.height / 2),
                withAttributes: checkAttrs)
        }
    }
}
