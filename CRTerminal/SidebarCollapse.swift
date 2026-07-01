import AppKit
import QuartzCore

/// Tweens the session rail's width between its full and collapsed sizes,
/// stepping the controller each frame so the rail, the content inset, and the
/// terminal it reveals move on a single clock — the custom-drawn rail would
/// tear under AppKit's `frame` animator proxy. Timing matches the design's
/// `cubic-bezier(.34,.02,.2,1)` over ~0.3 s.
@MainActor
final class SidebarCollapseAnimation {
    private let from: CGFloat
    private let to: CGFloat
    private let duration: CFTimeInterval
    private let easing = UnitBezier(0.34, 0.02, 0.2, 1)
    private let step: (CGFloat) -> Void
    private let completion: () -> Void
    private var startTime: CFTimeInterval = 0
    private var timer: Timer?

    init(from: CGFloat, to: CGFloat, duration: CFTimeInterval,
         step: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        self.from = from
        self.to = to
        self.duration = duration
        self.step = step
        self.completion = completion
    }

    func start() {
        startTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                // Self gone (window closed mid-animation): stop the runloop
                // timer so it doesn't fire forever.
                guard let self else { t.invalidate(); return }
                self.tick()
            }
        }
        // `.common` so the tween keeps running through window-resize tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops the tween where it is (the controller cancels before starting a
    /// reverse toggle, or when a tab switch snaps the geometry).
    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let elapsed = CACurrentMediaTime() - startTime
        let t = min(1, max(0, elapsed / duration))
        step(from + (to - from) * CGFloat(easing.value(for: t)))
        if t >= 1 {
            cancel()
            completion()
        }
    }
}

/// A unit cubic Bézier easing curve (WebKit's `UnitBezier`): solves x(t) = x
/// by Newton–Raphson with a bisection fallback, then evaluates y(t).
struct UnitBezier {
    private let ax, bx, cx, ay, by, cy: Double

    init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        cx = 3 * p1x
        bx = 3 * (p2x - p1x) - cx
        ax = 1 - cx - bx
        cy = 3 * p1y
        by = 3 * (p2y - p1y) - cy
        ay = 1 - cy - by
    }

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func sampleDX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    private func solveX(_ x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let error = sampleX(t) - x
            if abs(error) < 1e-6 { return t }
            let d = sampleDX(t)
            if abs(d) < 1e-6 { break }
            t -= error / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        if t < lo { return lo }
        if t > hi { return hi }
        while lo < hi {
            let value = sampleX(t)
            if abs(value - x) < 1e-6 { return t }
            if x > value { lo = t } else { hi = t }
            t = (hi - lo) * 0.5 + lo
        }
        return t
    }

    func value(for x: Double) -> Double { sampleY(solveX(x)) }
}

/// The leading-titlebar button (by the traffic lights) that collapses/expands
/// the session rail. Draws the design's panel glyph: a windowed rectangle with
/// a divider whose left strip fills in when the rail is collapsed.
final class SidebarToggleButton: NSView {
    var onClick: (() -> Void)?
    private var collapsed = false {
        didSet { if collapsed != oldValue { needsDisplay = true } }
    }
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    private static let size = NSSize(width: 30, height: 26)
    override var intrinsicContentSize: NSSize { Self.size }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        toolTip = "Collapse sidebar"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityTitle("Toggle sidebar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarToggleButton is created in code")
    }

    func setCollapsed(_ collapsed: Bool) {
        self.collapsed = collapsed
        toolTip = collapsed ? "Expand sidebar" : "Collapse sidebar"
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
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let color = NSColor.secondaryLabelColor
        // The windowed rectangle.
        let glyph = NSRect(x: bounds.midX - 9, y: bounds.midY - 7, width: 18, height: 14)
        let outline = NSBezierPath(roundedRect: glyph, xRadius: 3, yRadius: 3)
        outline.lineWidth = 1.4
        color.setStroke()
        outline.stroke()
        // Left strip: solid when collapsed, faint when expanded.
        let dividerX = glyph.minX + 6
        let panel = NSRect(
            x: glyph.minX + 1.4, y: glyph.minY + 1.4,
            width: dividerX - glyph.minX - 2.1, height: glyph.height - 2.8)
        color.withAlphaComponent(collapsed ? 0.9 : 0.3).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 1.5, yRadius: 1.5).fill()
        // The divider between strip and content.
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: dividerX, y: glyph.minY))
        divider.line(to: NSPoint(x: dividerX, y: glyph.maxY))
        divider.lineWidth = 1.4
        color.setStroke()
        divider.stroke()
    }
}
