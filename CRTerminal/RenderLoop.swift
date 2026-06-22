import CRTRendering
import IOKit.ps
import QuartzCore
import TerminalCore
import os

/// The per-window render thread: a CAMetalDisplayLink on a dedicated thread
/// pulls session snapshots and draws only when something changed, pausing
/// entirely when idle (ARCHITECTURE.md: idle = zero CPU, zero GPU).
nonisolated final class RenderLoop: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private struct ViewState: Equatable {
        var scrollOffset = 0
        var selection: Selection?
        var markedText: String?
        /// Cell span of the URL/path currently ⌘-hovered (drawn underlined).
        var hoveredLink: Selection?
        /// Every find match (dim highlight); the current one is bright. This
        /// list can span the whole scrollback, so it is deliberately excluded
        /// from `==` — `searchGeneration` (bumped whenever the list changes)
        /// stands in, keeping the per-frame change check O(1).
        var searchMatches: [Selection] = []
        var searchGeneration = 0
        var currentMatch: Selection?

        static func == (lhs: ViewState, rhs: ViewState) -> Bool {
            lhs.scrollOffset == rhs.scrollOffset
                && lhs.selection == rhs.selection
                && lhs.markedText == rhs.markedText
                && lhs.hoveredLink == rhs.hoveredLink
                && lhs.searchGeneration == rhs.searchGeneration
                && lhs.currentMatch == rhs.currentMatch
        }
    }

    private struct Shared {
        var viewState = ViewState()
        /// Forces a draw even when generation/inputs look unchanged
        /// (geometry or backing-scale changes).
        var poked = true
        var drawCount = 0
        /// After invalidate(), the link is dead — every entry point no-ops
        /// (removeFromSuperview re-enters via viewDidMoveToWindow → poke).
        var invalidated = false
        /// Hidden tab: the pane keeps its session and state but must not
        /// produce frames until revealed.
        var occluded = false
        /// This pane's CRT preset (sessions theme independently); nil
        /// falls back to the shared renderer's preset.
        var preset: CRTPreset?
    }

    private let link: CAMetalDisplayLink
    private let thread: Thread
    private let renderer: TerminalRenderer
    private weak var session: TerminalSession?
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    /// Per-pane effect surfaces + phosphor clocks (renderer is shared
    /// across the window's panes); render-thread only.
    private let context = SurfaceContext()

    // Render-thread-only state.
    private var lastGeneration: UInt64?
    private var lastViewState = ViewState()
    private var idleFrames = 0
    private var lastPowerCheck: CFTimeInterval = 0
    private var onBattery = false
    private var throttled = false

    /// Frames the link may idle through before pausing (lets brief bursts
    /// settle without pause/unpause churn).
    private static let pauseAfterIdleFrames = 30

    init(layer: CAMetalLayer, renderer: TerminalRenderer, session: TerminalSession) {
        self.renderer = renderer
        self.session = session
        link = CAMetalDisplayLink(metalLayer: layer)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60, maximum: 120, preferred: 120)

        let link = link
        thread = Thread {
            link.add(to: RunLoop.current, forMode: .default)
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "crterminal.render"
        thread.qualityOfService = .userInteractive
        super.init()
        link.delegate = self
        thread.start()
    }

    var drawCount: Int {
        shared.withLock { $0.drawCount }
    }

    var isPaused: Bool {
        link.isPaused
    }

    /// Something may have changed; make sure frames are being produced.
    func poke(force: Bool = false) {
        let blocked = shared.withLock { shared in
            if force { shared.poked = true }
            return shared.invalidated || shared.occluded
        }
        guard !blocked else { return }
        link.isPaused = false
    }

    func setViewState(
        scrollOffset: Int, selection: Selection?, markedText: String? = nil,
        hoveredLink: Selection? = nil, searchMatches: [Selection] = [],
        searchGeneration: Int = 0, currentMatch: Selection? = nil
    ) {
        let blocked = shared.withLock { shared in
            shared.viewState = ViewState(
                scrollOffset: scrollOffset, selection: selection,
                markedText: markedText, hoveredLink: hoveredLink,
                searchMatches: searchMatches, searchGeneration: searchGeneration,
                currentMatch: currentMatch)
            return shared.invalidated || shared.occluded
        }
        guard !blocked else { return }
        link.isPaused = false
    }

    /// The pane's preset changed (theme switch on its session).
    func setPreset(_ preset: CRTPreset) {
        let blocked = shared.withLock { shared in
            shared.preset = preset
            shared.poked = true
            return shared.invalidated || shared.occluded
        }
        guard !blocked else { return }
        link.isPaused = false
    }

    /// Tab switching: an occluded pane's link pauses immediately and stays
    /// paused through pokes; revealing forces a redraw of whatever arrived.
    func setOccluded(_ occluded: Bool) {
        let wake = shared.withLock { shared in
            shared.occluded = occluded
            if !occluded { shared.poked = true }
            return !occluded && !shared.invalidated
        }
        if occluded {
            link.isPaused = true
        } else if wake {
            link.isPaused = false
        }
    }

    /// Tear down on the link's own thread: invalidating from another
    /// thread races an in-flight callback against the layer's dealloc
    /// (observed as a use-after-free crash when closing split panes).
    func invalidate() {
        let alreadyInvalidated = shared.withLock { shared in
            defer { shared.invalidated = true }
            return shared.invalidated
        }
        guard !alreadyInvalidated else { return }
        link.isPaused = true
        perform(
            #selector(invalidateOnRenderThread), on: thread, with: nil,
            waitUntilDone: false)
    }

    @objc private func invalidateOnRenderThread() {
        link.invalidate()
        Thread.current.cancel() // the runloop spin in `thread` checks this
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard let session else { return }
        let (viewState, poked, preset, blocked) = shared.withLock { shared in
            defer { shared.poked = false }
            return (shared.viewState, shared.poked, shared.preset,
                    shared.invalidated || shared.occluded)
        }
        guard !blocked else { return }
        let state = session.snapshot
        let now = CACurrentMediaTime()
        let contentChanged = poked
            || state.generation != lastGeneration
            || viewState != lastViewState
        // Animated effects (persistence decay, noise, degauss) opt into
        // frames; the link still pauses once everything is quiescent, so
        // the idle-power contract holds with effects enabled.
        let animating = renderer.wantsContinuousFrames(
            at: now, context: context, preset: preset)
        if !contentChanged && !animating {
            idleFrames += 1
            if idleFrames >= Self.pauseAfterIdleFrames {
                link.isPaused = true
            }
            return
        }
        idleFrames = 0
        lastGeneration = state.generation
        lastViewState = viewState
        updateThrottle(animatingOnly: animating && !contentChanged, now: now)
        renderer.draw(
            state,
            scrollOffset: viewState.scrollOffset,
            selection: viewState.selection,
            markedText: viewState.markedText,
            hoveredLink: viewState.hoveredLink,
            searchMatches: viewState.searchMatches,
            currentMatch: viewState.currentMatch,
            contentChanged: contentChanged,
            at: now,
            preset: preset,
            context: context,
            into: update.drawable)
        shared.withLock { $0.drawCount += 1 }
    }

    /// Effects must not show up in Activity Monitor: when frames are being
    /// produced *only* for an effect animation and the machine is on
    /// battery (or Low Power Mode), drop to 30 Hz.
    private func updateThrottle(animatingOnly: Bool, now: CFTimeInterval) {
        if now - lastPowerCheck > 5 {
            lastPowerCheck = now
            onBattery = ProcessInfo.processInfo.isLowPowerModeEnabled
                || IOPSGetTimeRemainingEstimate() != kIOPSTimeRemainingUnlimited
        }
        let shouldThrottle = animatingOnly && onBattery
        guard shouldThrottle != throttled else { return }
        throttled = shouldThrottle
        link.preferredFrameRateRange = shouldThrottle
            ? CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            : CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    }
}
