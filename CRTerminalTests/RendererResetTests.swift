import AppKit
import CRTRendering
import Testing
@testable import CRTerminal

/// A renderer change (font, face, backing scale, moving windows) swaps the
/// renderer inside the pane's render loop. Rebuilding the loop put a second
/// display link on the layer and started the new one unhidden in a hidden
/// tab; panes rebuilt that way were the ones a freeze report found silent.
struct RendererResetTests {
    @Test @MainActor func aFontChangeKeepsEachPanesRenderLoopAndHiddenState() throws {
        let controller = TerminalWindowController(settings: TerminalSettings())
        defer { controller.window?.close() }
        controller.addSession()
        let hidden = try #require(controller.tabs[0].panes.first)
        let shown = try #require(controller.tabs[1].panes.first)
        let hiddenLoop = try #require(hidden.renderLoop)
        let shownLoop = try #require(shown.renderLoop)
        let oldRenderer = try #require(shown.renderer)
        #expect(hiddenLoop.health.occluded)
        #expect(!shownLoop.health.occluded)

        var bigger = TerminalSettings()
        bigger.fontSize = 20
        controller.apply(settings: bigger)

        #expect(hidden.renderLoop === hiddenLoop)
        #expect(shown.renderLoop === shownLoop)
        #expect(hiddenLoop.health.occluded)
        #expect(!shownLoop.health.occluded)
        let newRenderer = try #require(shown.renderer)
        #expect(newRenderer !== oldRenderer)
        #expect(newRenderer.cellSize.width > oldRenderer.cellSize.width)
    }
}

struct PresetPreviewCacheTests {
    @Test @MainActor func stillPresetsRenderOnceAndAnimatedOnesEveryTime() throws {
        let preview = PresetPreviewRenderer()
        var still = CRTPreset.darkStandard
        still.name = "test-still"
        still.text.boldShakePt = 0
        still.artifacts.noise = 0
        still.artifacts.humBar = 0
        still.artifacts.jitter = 0
        let first = try #require(preview.image(for: still, time: 1))
        let second = try #require(preview.image(for: still, time: 2))
        #expect(first === second)

        // An edit under the same name is a different look: render it afresh.
        var edited = still
        edited.scanlines.strength = still.scanlines.strength == 0.5 ? 0.25 : 0.5
        let third = try #require(preview.image(for: edited, time: 2))
        #expect(third !== second)

        var animated = still
        animated.name = "test-animated"
        animated.effects = true
        animated.artifacts.noise = 0.2
        let a = try #require(preview.image(for: animated, time: 1))
        let b = try #require(preview.image(for: animated, time: 2))
        #expect(a !== b)
    }
}
