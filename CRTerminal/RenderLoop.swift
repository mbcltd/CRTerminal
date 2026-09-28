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
        /// Bumped by every request for frames (poke, view state, preset,
        /// reveal); lets the render thread pause without losing a wake that
        /// raced its idle decision (see `pauseUnlessWoken`).
        var wakeRequests: UInt64 = 0
        /// Whether the window is on screen (not minimized, hidden or fully
        /// covered); the freeze watchdog expects no frames otherwise.
        var windowVisible = true
        // Freeze-watchdog bookkeeping (see `Health`).
        var lastDrawAt: CFTimeInterval?
        var lastDrawnGeneration: UInt64?
        var drawStartedAt: CFTimeInterval?
        var renderThread: thread_t = 0
    }

    private let link: CAMetalDisplayLink
    private let thread: Thread
    private let renderer: TerminalRenderer
    private weak var session: TerminalSession?
    private let createdAt = CACurrentMediaTime()
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
        let shared = shared
        thread = Thread {
            shared.withLock { $0.renderThread = pthread_mach_thread_np(pthread_self()) }
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
        FreezeWatchdog.shared.register(self)
    }

    var drawCount: Int {
        shared.withLock { $0.drawCount }
    }

    var isPaused: Bool {
        link.isPaused
    }

    /// Something may have changed; make sure frames are being produced.
    func poke(force: Bool = false) {
        wake { shared in
            if force { shared.poked = true }
        }
    }

    func setViewState(
        scrollOffset: Int, selection: Selection?, markedText: String? = nil,
        hoveredLink: Selection? = nil, searchMatches: [Selection] = [],
        searchGeneration: Int = 0, currentMatch: Selection? = nil
    ) {
        wake { shared in
            shared.viewState = ViewState(
                scrollOffset: scrollOffset, selection: selection,
                markedText: markedText, hoveredLink: hoveredLink,
                searchMatches: searchMatches, searchGeneration: searchGeneration,
                currentMatch: currentMatch)
        }
    }

    /// The pane's preset changed (theme switch on its session).
    func setPreset(_ preset: CRTPreset) {
        wake { shared in
            shared.preset = preset
            shared.poked = true
        }
    }

    /// Tab switching: an occluded pane's link pauses immediately and stays
    /// paused through pokes; revealing forces a redraw of whatever arrived.
    func setOccluded(_ occluded: Bool) {
        if occluded {
            shared.withLock { $0.occluded = true }
            link.isPaused = true
        } else {
            wake { shared in
                shared.occluded = false
                shared.poked = true
            }
        }
    }

    /// Window occlusion (minimized, hidden, covered): informational, for
    /// the freeze watchdog — the display link throttles itself.
    func setWindowVisible(_ visible: Bool) {
        shared.withLock { $0.windowVisible = visible }
    }

    /// Applies `update` and unpauses the link unless the pane is hidden or
    /// torn down. Every wake is counted, so a pause decided on older state
    /// can tell it was overtaken.
    private func wake(_ update: (inout Shared) -> Void) {
        let blocked = shared.withLock { shared in
            update(&shared)
            shared.wakeRequests &+= 1
            return shared.invalidated || shared.occluded
        }
        guard !blocked else { return }
        link.isPaused = false
    }

    /// Pauses the link unless a wake arrived after `wakeRequests` was read
    /// at the top of this callback. Without the re-check a poke landing
    /// between the callback's snapshot and `isPaused = true` was lost: its
    /// unpause hit a running link, then our pause overrode it, and output
    /// that had just arrived stayed undrawn until the next keystroke or
    /// output — a pane that looked frozen. Any later wake either shows up
    /// here or unpauses after this pause.
    private func pauseUnlessWoken(since wakeRequests: UInt64) {
        link.isPaused = true
        let woken = shared.withLock { shared in
            shared.wakeRequests != wakeRequests
                && !shared.invalidated && !shared.occluded
        }
        if woken { link.isPaused = false }
    }

    /// A point-in-time view of this pane's rendering for the freeze
    /// watchdog. Safe from any thread.
    struct Health {
        var occluded: Bool
        var invalidated: Bool
        var windowVisible: Bool
        var linkPaused: Bool
        var drawCount: Int
        var createdAt: CFTimeInterval
        var lastDrawAt: CFTimeInterval?
        var lastDrawnGeneration: UInt64?
        /// Set while a draw is in progress; a stale value means the render
        /// thread is stuck inside the renderer.
        var drawStartedAt: CFTimeInterval?
        var renderThread: thread_t
    }

    var health: Health {
        let linkPaused = link.isPaused
        return shared.withLock { shared in
            Health(
                occluded: shared.occluded, invalidated: shared.invalidated,
                windowVisible: shared.windowVisible, linkPaused: linkPaused,
                drawCount: shared.drawCount, createdAt: createdAt,
                lastDrawAt: shared.lastDrawAt,
                lastDrawnGeneration: shared.lastDrawnGeneration,
                drawStartedAt: shared.drawStartedAt,
                renderThread: shared.renderThread)
        }
    }

    /// The session this pane draws (weak; nil once it's gone).
    var terminalSession: TerminalSession? { session }

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
        let (viewState, poked, preset, blocked, wakeRequests) = shared.withLock { shared in
            defer { shared.poked = false }
            return (shared.viewState, shared.poked, shared.preset,
                    shared.invalidated || shared.occluded, shared.wakeRequests)
        }
        // A hidden pane's link can still be running (paused only after an
        // in-flight wake); stop it rather than spin through empty frames.
        guard !blocked else {
            pauseUnlessWoken(since: wakeRequests)
            return
        }
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
                pauseUnlessWoken(since: wakeRequests)
            }
            return
        }
        idleFrames = 0
        lastGeneration = state.generation
        lastViewState = viewState
        updateThrottle(animatingOnly: animating && !contentChanged, now: now)
        shared.withLock { $0.drawStartedAt = now }
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
        let generation = state.generation
        shared.withLock { shared in
            shared.drawCount += 1
            shared.drawStartedAt = nil
            shared.lastDrawAt = now
            shared.lastDrawnGeneration = generation
        }
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
