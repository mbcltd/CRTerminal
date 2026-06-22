import AppKit

/// Pure geometry for the overlay scrollbar — split out so the knob math is
/// unit-testable without AppKit layers. All rects are in `TerminalView`'s
/// flipped coordinates (y-down, origin top-left), matching the Metal surface
/// and the `bottomBarLayer` convention.
struct ScrollbarGeometry: Equatable {
    /// Full hover lane (the track region) in view coordinates.
    var lane: CGRect
    /// Current knob rectangle in view coordinates.
    var knob: CGRect
    /// Scrollback line count at compute time — the maximum scroll offset.
    var maxOffset: Int
    /// Vertical travel available to the knob's top edge.
    var available: CGFloat

    /// Knobs never shrink below this, so deep scrollback stays grabbable.
    static let minKnobLength: CGFloat = 24

    /// Builds geometry for a scroll position. `scrollOffset` is lines back from
    /// live (0 = pinned to the bottom), `maxOffset` is the scrollback depth.
    static func compute(
        lane: CGRect, scrollOffset: Int, maxOffset: Int, rows: Int,
        knobWidth: CGFloat
    ) -> ScrollbarGeometry {
        let total = max(1, maxOffset + rows)
        let visibleFraction = min(1, CGFloat(rows) / CGFloat(total))
        let knobLength = max(minKnobLength, (lane.height * visibleFraction).rounded())
        let available = max(0, lane.height - knobLength)
        // f = fraction scrolled back: 0 at live (knob at bottom), 1 at the
        // oldest line (knob at top).
        let f = maxOffset > 0
            ? min(1, max(0, CGFloat(scrollOffset) / CGFloat(maxOffset)))
            : 0
        let knobTop = lane.minY + available * (1 - f)
        let knob = CGRect(
            x: lane.maxX - knobWidth, y: knobTop,
            width: knobWidth, height: knobLength)
        return ScrollbarGeometry(
            lane: lane, knob: knob, maxOffset: maxOffset, available: available)
    }

    /// The scroll offset (lines back from live) for a knob whose top edge sits
    /// at `knobTop`, clamped to `0...maxOffset`.
    func offset(forKnobTop knobTop: CGFloat) -> Int {
        guard available > 0, maxOffset > 0 else { return 0 }
        let clamped = min(max(lane.minY, knobTop), lane.minY + available)
        let f = 1 - (clamped - lane.minY) / available
        return min(max(0, Int((f * CGFloat(maxOffset)).rounded())), maxOffset)
    }

    func hitsKnob(_ point: CGPoint) -> Bool { knob.contains(point) }
    func hitsLane(_ point: CGPoint) -> Bool { lane.contains(point) }
}

/// A macOS-idiomatic overlay scrollbar drawn with CALayers above the Metal
/// surface (the same approach as `TerminalView.bottomBarLayer`). It is hidden
/// at rest, flashes in on scroll and fades out when idle, and expands on hover.
/// It owns the right-edge gutter lane so the upcoming search-annotated rail can
/// reuse `ScrollbarGeometry`'s line↔y mapping and share the lane.
@MainActor
final class ScrollbarOverlay {
    /// Knob width at rest vs. while hovered/dragged (the standard overlay grow).
    private let restKnobWidth: CGFloat = 7
    private let activeKnobWidth: CGFloat = 11
    /// Gap from the view's right edge.
    private let rightMargin: CGFloat = 2
    /// How long the knob lingers after the last scroll before fading out.
    private let lingerSeconds: TimeInterval = 1.1
    private let fadeDuration: TimeInterval = 0.18

    private let trackLayer = CALayer()
    private let knobLayer = CALayer()
    private var fadeTimer: Timer?

    private(set) var geometry: ScrollbarGeometry?
    private var hovering = false
    private var dragging = false
    private var flashing = false
    /// Last inputs to `update`, so a hover/drag change can re-lay-out the knob
    /// (its width changes) without waiting for the next scroll.
    private var lastInputs: Inputs?

    private struct Inputs: Equatable {
        var viewSize: CGSize
        var top: CGFloat
        var bottom: CGFloat
        var scrollOffset: Int
        var scrollbackCount: Int
        var rows: Int
        var isLight: Bool
        var suppressed: Bool
    }

    /// When the system preference is "Always" (legacy), the bar stays visible
    /// rather than fading.
    private var alwaysVisible: Bool { NSScroller.preferredScrollerStyle == .legacy }
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Width of the gutter lane — a shared constant for the future search rail.
    var laneWidth: CGFloat { activeKnobWidth + rightMargin }

    /// Whether the bar is currently shown — gates whether gutter clicks are
    /// intercepted (a hidden bar lets clicks fall through to the terminal).
    var isVisible: Bool { shouldShow }

    init() {
        for layer in [trackLayer, knobLayer] {
            layer.cornerRadius = 3
            // No implicit animations on geometry; opacity is animated explicitly.
            layer.actions = [
                "position": NSNull(), "bounds": NSNull(),
                "frame": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull(),
            ]
            layer.opacity = 0
        }
    }

    func attach(to host: CALayer) {
        if trackLayer.superlayer == nil { host.addSublayer(trackLayer) }
        if knobLayer.superlayer == nil { host.addSublayer(knobLayer) }
    }

    /// Recomputes the knob for a scroll position and theme. `top`/`bottom` bound
    /// the grid's vertical extent. `suppressed` hides the bar entirely (no
    /// scrollback, or an alt-screen app owns scrolling).
    func update(
        viewSize: CGSize, top: CGFloat, bottom: CGFloat,
        scrollOffset: Int, scrollbackCount: Int, rows: Int,
        isLight: Bool, suppressed: Bool
    ) {
        lastInputs = Inputs(
            viewSize: viewSize, top: top, bottom: bottom,
            scrollOffset: scrollOffset, scrollbackCount: scrollbackCount,
            rows: rows, isLight: isLight, suppressed: suppressed)

        guard !suppressed, bottom > top, scrollbackCount > 0 else {
            geometry = nil
            flashing = false
            fadeTimer?.invalidate()
            applyOpacities(animated: true)
            return
        }

        let knobWidth = (hovering || dragging) ? activeKnobWidth : restKnobWidth
        let lane = CGRect(
            x: viewSize.width - rightMargin - activeKnobWidth, y: top,
            width: activeKnobWidth, height: bottom - top)
        let geo = ScrollbarGeometry.compute(
            lane: lane, scrollOffset: scrollOffset, maxOffset: scrollbackCount,
            rows: rows, knobWidth: knobWidth)
        geometry = geo

        let mono: CGFloat = isLight ? 0 : 1
        let knobAlpha: CGFloat = (hovering || dragging) ? 0.55 : 0.34
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        knobLayer.frame = geo.knob
        knobLayer.backgroundColor = NSColor(white: mono, alpha: knobAlpha).cgColor
        // A faint full-height track, only meaningful while expanded.
        trackLayer.frame = CGRect(
            x: lane.maxX - activeKnobWidth, y: lane.minY,
            width: activeKnobWidth, height: lane.height)
        trackLayer.backgroundColor = NSColor(white: mono, alpha: 0.08).cgColor
        CATransaction.commit()

        applyOpacities(animated: true)
    }

    /// Shows the knob, then schedules a fade-out — call on every scroll.
    func flash() {
        guard geometry != nil else { return }
        flashing = true
        applyOpacities(animated: true)
        scheduleFade()
    }

    func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        relayout()
        if !value { scheduleFade() } else { fadeTimer?.invalidate() }
    }

    func beginDrag() {
        dragging = true
        flashing = true
        fadeTimer?.invalidate()
        relayout()
    }

    func endDrag() {
        dragging = false
        relayout()
        scheduleFade()
    }

    // MARK: - Internals

    private var shouldShow: Bool {
        geometry != nil && (alwaysVisible || flashing || hovering || dragging)
    }

    private func relayout() {
        guard let inputs = lastInputs else { return }
        update(
            viewSize: inputs.viewSize, top: inputs.top, bottom: inputs.bottom,
            scrollOffset: inputs.scrollOffset, scrollbackCount: inputs.scrollbackCount,
            rows: inputs.rows, isLight: inputs.isLight, suppressed: inputs.suppressed)
    }

    private func scheduleFade() {
        fadeTimer?.invalidate()
        guard !alwaysVisible, !hovering, !dragging else { return }
        fadeTimer = Timer.scheduledTimer(
            withTimeInterval: lingerSeconds, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flashing = false
                self.applyOpacities(animated: true)
            }
        }
    }

    private func applyOpacities(animated: Bool) {
        let show = shouldShow
        let knobTarget: Float = show ? 1 : 0
        let trackTarget: Float = (show && (hovering || dragging || alwaysVisible)) ? 1 : 0
        setOpacity(knobLayer, to: knobTarget, animated: animated)
        setOpacity(trackLayer, to: trackTarget, animated: animated)
    }

    private func setOpacity(_ layer: CALayer, to target: Float, animated: Bool) {
        guard layer.opacity != target else { return }
        if animated && !reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = target
            fade.duration = fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "opacity")
        }
        layer.opacity = target
    }
}
