import CoreGraphics
import Foundation
import ImageIO
import Metal
import TerminalCore

/// Decodes inline images to GPU textures and caches them by internal serial.
/// Kept per-pane (on `SurfaceContext`) because image serials restart per
/// session, so a window-shared renderer can't key on them alone. Textures are
/// premultiplied RGBA so they composite with the same blend as color glyphs.
public final class ImageTextureCache {
    private let device: MTLDevice
    private var textures: [UInt32: MTLTexture] = [:]

    public init(device: MTLDevice) {
        self.device = device
    }

    /// The texture for an image, decoding+uploading on first use.
    func texture(for image: TerminalImage) -> MTLTexture? {
        if let cached = textures[image.id] { return cached }
        guard let texture = makeTexture(image) else { return nil }
        textures[image.id] = texture
        return texture
    }

    /// Drop textures whose images are gone (placement evicted, deleted, …).
    func purge(keeping liveIDs: Set<UInt32>) {
        guard textures.count > liveIDs.count else { return }
        textures = textures.filter { liveIDs.contains($0.key) }
    }

    private func makeTexture(_ image: TerminalImage) -> MTLTexture? {
        let rgba: [UInt8]
        let width: Int
        let height: Int
        switch image.format {
        case .rgba:
            width = image.pixelWidth
            height = image.pixelHeight
            rgba = Self.premultiply(image.bytes, width: width, height: height)
        case .rgb:
            width = image.pixelWidth
            height = image.pixelHeight
            rgba = Self.expandRGB(image.bytes, width: width, height: height)
        case .encoded:
            guard let decoded = Self.decodeEncoded(image.bytes) else { return nil }
            width = decoded.width
            height = decoded.height
            rgba = decoded.pixels
        }
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        rgba.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    /// Straight-alpha RGBA → premultiplied (no-op for the common opaque case).
    private static func premultiply(_ bytes: [UInt8], width: Int, height: Int) -> [UInt8] {
        let count = width * height * 4
        guard bytes.count >= count else { return bytes }
        var out = bytes
        var i = 0
        while i < count {
            let a = UInt32(out[i + 3])
            if a != 255 {
                out[i] = UInt8(UInt32(out[i]) * a / 255)
                out[i + 1] = UInt8(UInt32(out[i + 1]) * a / 255)
                out[i + 2] = UInt8(UInt32(out[i + 2]) * a / 255)
            }
            i += 4
        }
        return out
    }

    private static func expandRGB(_ bytes: [UInt8], width: Int, height: Int) -> [UInt8] {
        let pixels = width * height
        guard bytes.count >= pixels * 3 else { return [] }
        var out = [UInt8](repeating: 255, count: pixels * 4)
        for p in 0..<pixels {
            out[p * 4] = bytes[p * 3]
            out[p * 4 + 1] = bytes[p * 3 + 1]
            out[p * 4 + 2] = bytes[p * 3 + 2]
        }
        return out
    }

    /// Decode a container (PNG/JPEG/GIF/…) to premultiplied RGBA via ImageIO.
    private static func decodeEncoded(_ bytes: [UInt8]) -> (width: Int, height: Int, pixels: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = pixels.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: info)
        }) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, pixels)
    }
}
