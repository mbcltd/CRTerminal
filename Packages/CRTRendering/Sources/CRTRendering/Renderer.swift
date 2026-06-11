import Metal
import QuartzCore

/// Owns the Metal device, command queue, and (eventually) the glyph atlas and
/// render pipelines for one window. Phase 0: clears a drawable to a color.
public final class Renderer {
    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue
    }

    /// Encodes a pass that clears `texture`. The caller commits the returned
    /// command buffer (after scheduling a present, if drawing to a layer).
    public func makeClearCommandBuffer(texture: MTLTexture, color: MTLClearColor) -> MTLCommandBuffer? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = color
        guard let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            return nil
        }
        encoder.endEncoding()
        return buffer
    }

    /// Clears the layer's next drawable and presents it.
    public func clear(_ layer: CAMetalLayer, color: MTLClearColor) {
        autoreleasepool {
            guard let drawable = layer.nextDrawable(),
                  let buffer = makeClearCommandBuffer(texture: drawable.texture, color: color) else {
                return
            }
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
