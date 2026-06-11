import CoreGraphics
import CoreText
import Foundation
import Metal
import QuartzCore
import TerminalCore
import os

/// Draws a `TerminalState` snapshot as instanced cell quads + glyph quads.
/// One renderer per window; owns the device, pipelines and glyph atlas.
public final class TerminalRenderer {
    public let device: MTLDevice
    /// Cell size in points (pixels = points × scale).
    public let cellSize: CGSize
    public let scale: CGFloat
    public var scheme: ColorScheme

    private let commandQueue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let colorGlyphPipeline: MTLRenderPipelineState
    private let atlas: GlyphAtlas
    private let ascent: CGFloat

    /// Keypress→photon latency probe; samples recorded around presents.
    private let latency = OSAllocatedUnfairLock<(pendingInput: CFTimeInterval?, samples: [Double])>(
        initialState: (nil, []))

    private struct Uniforms {
        var viewport: SIMD2<Float>
    }

    private struct BgInstance {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var color: UInt32
    }

    private struct GlyphInstance {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var uvOrigin: SIMD2<Float>
        var uvSize: SIMD2<Float>
        var color: UInt32
    }

    public init?(font: CTFont, scale: CGFloat, scheme: ColorScheme = .default) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let atlas = GlyphAtlas(device: device, font: font, scale: scale)
        else { return nil }
        self.device = device
        self.commandQueue = queue
        self.atlas = atlas
        self.scale = scale
        self.scheme = scheme

        // Monospace cell metrics from the font.
        var glyph = CGGlyph(0)
        var advance = CGSize.zero
        var character = UniChar(0x30) // '0'
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .default, &glyph, &advance, 1)
        ascent = CTFontGetAscent(font)
        let height = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        cellSize = CGSize(width: advance.width.rounded(.up), height: height.rounded(.up))

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)

            let bg = MTLRenderPipelineDescriptor()
            bg.vertexFunction = library.makeFunction(name: "bg_vertex")
            bg.fragmentFunction = library.makeFunction(name: "bg_fragment")
            bg.colorAttachments[0].pixelFormat = .bgra8Unorm
            bgPipeline = try device.makeRenderPipelineState(descriptor: bg)

            let glyphDescriptor = MTLRenderPipelineDescriptor()
            glyphDescriptor.vertexFunction = library.makeFunction(name: "glyph_vertex")
            glyphDescriptor.fragmentFunction = library.makeFunction(name: "glyph_fragment")
            let attachment = glyphDescriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            glyphPipeline = try device.makeRenderPipelineState(descriptor: glyphDescriptor)

            // Color glyphs arrive premultiplied; blend with (1, 1-srcAlpha).
            let colorDescriptor = MTLRenderPipelineDescriptor()
            colorDescriptor.vertexFunction = library.makeFunction(name: "glyph_vertex")
            colorDescriptor.fragmentFunction = library.makeFunction(name: "color_glyph_fragment")
            let colorAttachment = colorDescriptor.colorAttachments[0]!
            colorAttachment.pixelFormat = .bgra8Unorm
            colorAttachment.isBlendingEnabled = true
            colorAttachment.rgbBlendOperation = .add
            colorAttachment.alphaBlendOperation = .add
            colorAttachment.sourceRGBBlendFactor = .one
            colorAttachment.sourceAlphaBlendFactor = .one
            colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            colorGlyphPipeline = try device.makeRenderPipelineState(descriptor: colorDescriptor)
        } catch {
            return nil
        }
    }

    /// Render-thread entry: draws into a drawable provided by
    /// CAMetalDisplayLink (never calls nextDrawable).
    public func draw(
        _ state: TerminalState,
        scrollOffset: Int = 0,
        selection: Selection? = nil,
        into drawable: CAMetalDrawable
    ) {
        autoreleasepool {
            guard let buffer = encode(
                state, scrollOffset: scrollOffset, selection: selection,
                to: drawable.texture) else { return }
            attachLatencySample(to: buffer)
            buffer.present(drawable)
            buffer.commit()
        }
    }

    // MARK: Drawing

    public func draw(
        _ state: TerminalState,
        scrollOffset: Int = 0,
        selection: Selection? = nil,
        into layer: CAMetalLayer
    ) {
        autoreleasepool {
            guard let drawable = layer.nextDrawable() else { return }
            draw(state, scrollOffset: scrollOffset, selection: selection, into: drawable)
        }
    }

    private func attachLatencySample(to buffer: MTLCommandBuffer) {
        let pendingInput = latency.withLock { state in
            defer { state.pendingInput = nil }
            return state.pendingInput
        }
        guard let pendingInput else { return }
        // Completed ≈ presented for this workload, and unlike
        // addPresentedHandler it also fires when launched headless.
        buffer.addCompletedHandler { [latency] _ in
            let now = CACurrentMediaTime()
            latency.withLock {
                $0.samples.append(now - pendingInput)
            }
        }
    }

    /// Offscreen render with CPU readback — drives render tests and the
    /// debug probe, and seeds Phase 4's snapshot testing.
    public func renderImage(
        _ state: TerminalState,
        scrollOffset: Int = 0,
        selection: Selection? = nil
    ) -> CGImage? {
        let width = max(1, Int(CGFloat(state.columns) * cellSize.width * scale))
        let height = max(1, Int(CGFloat(state.rows) * cellSize.height * scale))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = encode(
                state, scrollOffset: scrollOffset, selection: selection,
                to: texture) else { return nil }
        buffer.commit()
        buffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }

    // MARK: Latency probe

    /// Call when user input is sent to the PTY; the next present records a
    /// sample.
    public func markInput() {
        let now = CACurrentMediaTime()
        latency.withLock { state in
            if state.pendingInput == nil { state.pendingInput = now }
        }
    }

    public func takeLatencySamples() -> [Double] {
        latency.withLock { state in
            defer { state.samples.removeAll() }
            return state.samples
        }
    }

    // MARK: Encoding

    private func encode(
        _ state: TerminalState,
        scrollOffset: Int,
        selection: Selection?,
        to texture: MTLTexture
    ) -> MTLCommandBuffer? {
        let cellW = Float(cellSize.width * scale)
        let cellH = Float(cellSize.height * scale)
        let baselineOffset = Float(ascent * scale)
        let lineThickness = max(1, Float(scale))

        let offset = min(max(0, scrollOffset), state.scrollback.count)
        let viewport = state.viewportLines(scrollOffset: offset)
        let viewportTop = state.absoluteScreenTop - offset
        let cursorVisible = offset == 0 && state.modes.cursorVisible

        var bgInstances: [BgInstance] = []
        var glyphInstances: [GlyphInstance] = []
        var colorGlyphInstances: [GlyphInstance] = []
        var overlayInstances: [BgInstance] = [] // decorations + thin cursors
        bgInstances.reserveCapacity(64)
        glyphInstances.reserveCapacity(state.columns * state.rows / 2)

        for y in 0..<viewport.count {
            let row = viewport[y]
            for x in 0..<min(state.columns, row.count) {
                let cell = row[x]
                let isBlockCursor = cursorVisible && state.cursorStyle == .block
                    && state.cursor.x == x && state.cursor.y == y
                let selected = selection?.contains(row: viewportTop + y, column: x) ?? false
                var (fg, bg) = resolveColors(cell, isCursor: isBlockCursor)
                if selected && !isBlockCursor {
                    bg = scheme.selectionBackground
                }

                let origin = SIMD2(Float(x) * cellW, Float(y) * cellH)
                if bg != scheme.background {
                    bgInstances.append(BgInstance(
                        origin: origin, size: SIMD2(cellW, cellH), color: bg))
                }
                if cell.glyph != Cell.blank.glyph,
                   !cell.attributes.contains(.wideSpacer),
                   let entry = atlas.entry(forScalar: cell.glyph), !entry.isEmpty {
                    let instance = GlyphInstance(
                        origin: SIMD2(
                            origin.x + entry.bearing.x,
                            origin.y + baselineOffset - entry.bearing.y),
                        size: entry.size,
                        uvOrigin: entry.uvOrigin,
                        uvSize: entry.uvSize,
                        color: fg)
                    if entry.isColor {
                        colorGlyphInstances.append(instance)
                    } else {
                        glyphInstances.append(instance)
                    }
                }
                let cellSpan = cell.attributes.contains(.wide) ? cellW * 2 : cellW
                if cell.attributes.contains(.underlined) {
                    overlayInstances.append(BgInstance(
                        origin: SIMD2(origin.x, origin.y + baselineOffset + lineThickness),
                        size: SIMD2(cellSpan, lineThickness),
                        color: fg))
                }
                if cell.attributes.contains(.struckThrough) {
                    overlayInstances.append(BgInstance(
                        origin: SIMD2(origin.x, origin.y + cellH * 0.5),
                        size: SIMD2(cellSpan, lineThickness),
                        color: fg))
                }
            }
        }

        // Bar/underline cursor overlays (block is drawn via cell inversion).
        if cursorVisible && state.cursorStyle != .block {
            let origin = SIMD2(Float(state.cursor.x) * cellW, Float(state.cursor.y) * cellH)
            switch state.cursorStyle {
            case .bar:
                overlayInstances.append(BgInstance(
                    origin: origin,
                    size: SIMD2(max(1, Float(scale)), cellH),
                    color: scheme.foreground))
            case .underline:
                overlayInstances.append(BgInstance(
                    origin: SIMD2(origin.x, origin.y + cellH - lineThickness * 2),
                    size: SIMD2(cellW, lineThickness * 2),
                    color: scheme.foreground))
            case .block:
                break
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor(scheme.background)

        guard let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return nil }

        var uniforms = Uniforms(viewport: SIMD2(Float(texture.width), Float(texture.height)))

        // setVertexBytes caps at 4 KiB; instance arrays go in real buffers.
        if !bgInstances.isEmpty,
           let instanceBuffer = device.makeBuffer(
            bytes: bgInstances,
            length: bgInstances.count * MemoryLayout<BgInstance>.stride,
            options: .storageModeShared) {
            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(
                type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                instanceCount: bgInstances.count)
        }
        if !glyphInstances.isEmpty,
           let instanceBuffer = device.makeBuffer(
            bytes: glyphInstances,
            length: glyphInstances.count * MemoryLayout<GlyphInstance>.stride,
            options: .storageModeShared) {
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.drawPrimitives(
                type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                instanceCount: glyphInstances.count)
        }
        if !colorGlyphInstances.isEmpty,
           let instanceBuffer = device.makeBuffer(
            bytes: colorGlyphInstances,
            length: colorGlyphInstances.count * MemoryLayout<GlyphInstance>.stride,
            options: .storageModeShared) {
            encoder.setRenderPipelineState(colorGlyphPipeline)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(atlas.colorTexture, index: 0)
            encoder.drawPrimitives(
                type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                instanceCount: colorGlyphInstances.count)
        }
        if !overlayInstances.isEmpty,
           let instanceBuffer = device.makeBuffer(
            bytes: overlayInstances,
            length: overlayInstances.count * MemoryLayout<BgInstance>.stride,
            options: .storageModeShared) {
            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(
                type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                instanceCount: overlayInstances.count)
        }
        encoder.endEncoding()
        return buffer
    }

    private func resolveColors(_ cell: Cell, isCursor: Bool) -> (fg: UInt32, bg: UInt32) {
        let attrs = cell.attributes
        var fg = scheme.resolve(cell.foreground, isForeground: true, bold: attrs.contains(.bold))
        var bg = scheme.resolve(cell.background, isForeground: false, bold: false)
        if attrs.contains(.inverse) != isCursor { // inverse XOR block cursor
            swap(&fg, &bg)
        }
        if attrs.contains(.hidden) {
            fg = bg
        }
        if attrs.contains(.faint) {
            fg = Self.dim(fg)
        }
        return (fg, bg)
    }

    private static func dim(_ color: UInt32) -> UInt32 {
        let r = UInt32(Double((color >> 24) & 0xFF) * 0.6)
        let g = UInt32(Double((color >> 16) & 0xFF) * 0.6)
        let b = UInt32(Double((color >> 8) & 0xFF) * 0.6)
        return r << 24 | g << 16 | b << 8 | (color & 0xFF)
    }

    private func clearColor(_ packed: UInt32) -> MTLClearColor {
        MTLClearColor(
            red: Double((packed >> 24) & 0xFF) / 255,
            green: Double((packed >> 16) & 0xFF) / 255,
            blue: Double((packed >> 8) & 0xFF) / 255,
            alpha: Double(packed & 0xFF) / 255)
    }
}
