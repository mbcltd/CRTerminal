import AppKit
import CRTRendering
import Metal
import QuartzCore

/// Hosts the CAMetalLayer the renderer draws into. Phase 0: clears to a dark
/// not-quite-black with a hint of phosphor green so a working Metal surface is
/// distinguishable from a plain black window.
final class MetalView: NSView {
    private let renderer = Renderer()

    private static let screenOffColor = MTLClearColor(red: 0.015, green: 0.04, blue: 0.025, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MetalView is created in code")
    }

    private var metalLayer: CAMetalLayer? {
        layer as? CAMetalLayer
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer?.device
        layer.pixelFormat = .bgra8Unorm
        return layer
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        redraw()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    private func redraw() {
        guard let renderer, let metalLayer, let window else { return }
        metalLayer.contentsScale = window.backingScaleFactor
        let backingSize = convertToBacking(bounds).size
        guard backingSize.width > 0, backingSize.height > 0 else { return }
        metalLayer.drawableSize = backingSize
        renderer.clear(metalLayer, color: Self.screenOffColor)
    }
}
