import Metal
import Testing
@testable import CRTRendering

struct RendererTests {
    @Test func clearFillsTextureWithColor() throws {
        guard let renderer = Renderer() else {
            // No Metal device available (unexpected on any supported Mac, but
            // don't fail the suite over missing hardware in a CI sandbox).
            return
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))

        let buffer = try #require(renderer.makeClearCommandBuffer(
            texture: texture,
            color: MTLClearColor(red: 0, green: 1, blue: 0, alpha: 1)))
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.status == .completed)

        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!,
                bytesPerRow: 4 * 4,
                from: MTLRegionMake2D(0, 0, 4, 4),
                mipmapLevel: 0)
        }
        // Every pixel should be opaque green.
        for cell in stride(from: 0, to: pixels.count, by: 4) {
            #expect(Array(pixels[cell..<cell + 4]) == [0, 255, 0, 255])
        }
    }
}
