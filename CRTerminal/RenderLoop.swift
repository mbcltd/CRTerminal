import CRTRendering
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
    }

    private struct Shared {
        var viewState = ViewState()
        /// Forces a draw even when generation/inputs look unchanged
        /// (geometry or backing-scale changes).
        var poked = true
        var drawCount = 0
    }

    private let link: CAMetalDisplayLink
    private let thread: Thread
    private let renderer: TerminalRenderer
    private weak var session: TerminalSession?
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    // Render-thread-only state.
    private var lastGeneration: UInt64?
    private var lastViewState = ViewState()
    private var idleFrames = 0

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
        if force {
            shared.withLock { $0.poked = true }
        }
        link.isPaused = false
    }

    func setViewState(scrollOffset: Int, selection: Selection?) {
        shared.withLock {
            $0.viewState = ViewState(scrollOffset: scrollOffset, selection: selection)
        }
        link.isPaused = false
    }

    func invalidate() {
        link.invalidate()
        thread.cancel()
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard let session else { return }
        let (viewState, poked) = shared.withLock { shared in
            defer { shared.poked = false }
            return (shared.viewState, shared.poked)
        }
        let state = session.snapshot
        if !poked, state.generation == lastGeneration, viewState == lastViewState {
            idleFrames += 1
            if idleFrames >= Self.pauseAfterIdleFrames {
                link.isPaused = true
            }
            return
        }
        idleFrames = 0
        lastGeneration = state.generation
        lastViewState = viewState
        renderer.draw(
            state,
            scrollOffset: viewState.scrollOffset,
            selection: viewState.selection,
            into: update.drawable)
        shared.withLock { $0.drawCount += 1 }
    }
}
