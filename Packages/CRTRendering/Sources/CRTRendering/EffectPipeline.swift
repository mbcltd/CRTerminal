import Metal
import QuartzCore

/// GPU-facing uniforms derived from a CRTPreset. Field order matches the
/// MSL struct in EffectShaders.swift; the float2/float3 fields keep both
/// layouts in lockstep (24 scalars = 96 bytes before the first float3).
struct CRTUniforms {
    var viewport: SIMD2<Float> = .zero
    var screenOrigin: SIMD2<Float> = .zero
    var screenSize: SIMD2<Float> = .one
    var time: Float = 0
    var degaussPhase: Float = 1
    var curvature: Float = 0
    var cornerRadius: Float = 0
    var vignette: Float = 0
    var maskType: Float = 0
    var maskPitchPx: Float = 1
    var maskStrength: Float = 0
    var scanLines: Float = 0
    var scanStrength: Float = 0
    var beamWidth: Float = 0.8
    var bloomStrength: Float = 0
    var noise: Float = 0
    var humBar: Float = 0
    var jitter: Float = 0
    var convergencePx: Float = 0
    var aberration: Float = 0
    var monochrome: Float = 0
    var tint: SIMD3<Float> = .one
    var bezelColor: SIMD3<Float> = .zero
    var bezelPx: Float = 0

    /// Nominal Mac panel: ~110 points per inch.
    static func pixelsPerMM(scale: CGFloat) -> Float {
        Float(scale) * 110.0 / 25.4
    }

    init(preset: CRTPreset, width: Int, height: Int, scale: CGFloat,
         time: CFTimeInterval, degaussPhase: Float) {
        let pxPerMM = Self.pixelsPerMM(scale: scale)
        viewport = SIMD2(Float(width), Float(height))
        bezelPx = Float(preset.bezel.widthPt) * Float(scale)
        // Keep at least a sliver of screen even at silly bezel sizes.
        bezelPx = min(bezelPx, 0.4 * min(viewport.x, viewport.y))
        screenOrigin = SIMD2(bezelPx / viewport.x, bezelPx / viewport.y)
        screenSize = SIMD2(1 - 2 * screenOrigin.x, 1 - 2 * screenOrigin.y)

        self.time = Float(time.truncatingRemainder(dividingBy: 3600))
        self.degaussPhase = degaussPhase
        curvature = Float(preset.geometry.curvature)
        cornerRadius = Float(preset.geometry.cornerRadius)
        vignette = Float(preset.geometry.vignette)

        switch preset.mask.type {
        case .none: maskType = 0
        case .aperture: maskType = 1
        case .slot: maskType = 2
        case .shadow: maskType = 3
        }
        maskPitchPx = max(Float(preset.mask.pitchMM) * pxPerMM, 1.5)
        maskStrength = Float(preset.mask.strength)

        scanLines = Float(preset.scanlines.lines)
        scanStrength = Float(preset.scanlines.strength)
        beamWidth = Float(preset.scanlines.beamWidth)

        bloomStrength = Float(preset.bloom.strength)
        noise = Float(preset.artifacts.noise)
        humBar = Float(preset.artifacts.humBar)
        jitter = Float(preset.artifacts.jitter)
        convergencePx = Float(preset.artifacts.convergenceMM) * pxPerMM
        aberration = Float(preset.artifacts.aberration)
        monochrome = preset.phosphor.monochrome ? 1 : 0
        tint = preset.phosphor.color.simd
        bezelColor = preset.bezel.color.simd
    }
}

/// The offscreen textures the effect chain renders through, sized to the
/// output. Owned by whoever drives a draw loop (the renderer keeps one for
/// the live surface; renderImage builds a throwaway set), so concurrent
/// offscreen renders never share mutable state.
struct EffectSurfaces {
    let width: Int
    let height: Int
    let terminal: MTLTexture
    var persistence: [MTLTexture] // ping-pong pair
    var persistenceIndex = 0
    /// False until the pair holds a real frame; the first pass after a
    /// reset ignores history.
    var persistenceValid = false
    let bloomA: MTLTexture // half resolution
    let bloomB: MTLTexture

    init?(device: MTLDevice, width: Int, height: Int) {
        func make(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: max(w, 1), height: max(h, 1), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        guard let terminal = make(.bgra8Unorm, width, height),
              let p0 = make(.rgba16Float, width, height),
              let p1 = make(.rgba16Float, width, height),
              let bloomA = make(.rgba16Float, width / 2, height / 2),
              let bloomB = make(.rgba16Float, width / 2, height / 2)
        else { return nil }
        self.width = width
        self.height = height
        self.terminal = terminal
        persistence = [p0, p1]
        self.bloomA = bloomA
        self.bloomB = bloomB
    }
}

/// Compiled pipeline states for the effect chain. Immutable after init and
/// safe to share across threads.
final class EffectPipeline {
    private let persistencePipeline: MTLRenderPipelineState
    private let extractPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState

    init?(device: MTLDevice) {
        guard let library = try? device.makeLibrary(source: effectShaderSource, options: nil),
              let fsq = library.makeFunction(name: "fsq_vertex")
        else { return nil }

        func pipeline(_ fragment: String, format: MTLPixelFormat) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = fsq
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let persistence = pipeline("persistence_fragment", format: .rgba16Float),
              let extract = pipeline("bloom_extract_fragment", format: .rgba16Float),
              let blur = pipeline("blur_fragment", format: .rgba16Float),
              let composite = pipeline("crt_composite", format: .bgra8Unorm)
        else { return nil }
        persistencePipeline = persistence
        extractPipeline = extract
        blurPipeline = blur
        compositePipeline = composite
    }

    /// Appends the effect passes to `buffer`, reading `surfaces.terminal`
    /// and writing the final composite into `output`.
    /// - Parameters:
    ///   - decayFactor: per-frame phosphor retention, exp(-dt/tau); pass 0
    ///     to disable/reset persistence.
    ///   - bloomThreshold/SigmaPx: bloom extract + blur parameters; bloom
    ///     passes are skipped when uniforms.bloomStrength is 0.
    func encode(
        into buffer: MTLCommandBuffer,
        surfaces: inout EffectSurfaces,
        output: MTLTexture,
        uniforms: CRTUniforms,
        decayFactor: Float,
        bloomThreshold: Float,
        bloomSigmaPx: Float
    ) {
        func pass(_ target: MTLTexture, _ body: (MTLRenderCommandEncoder) -> Void) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            body(encoder)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // 1. Persistence: blend with the previous frame at the decay rate.
        var source: MTLTexture = surfaces.terminal
        if decayFactor > 0 {
            let previous = surfaces.persistence[surfaces.persistenceIndex]
            let current = surfaces.persistence[1 - surfaces.persistenceIndex]
            var persistence = PersistenceUniforms(
                decay: surfaces.persistenceValid ? decayFactor : 0)
            pass(current) { encoder in
                encoder.setRenderPipelineState(persistencePipeline)
                encoder.setFragmentTexture(surfaces.terminal, index: 0)
                encoder.setFragmentTexture(previous, index: 1)
                encoder.setFragmentBytes(
                    &persistence, length: MemoryLayout<PersistenceUniforms>.stride, index: 0)
            }
            surfaces.persistenceIndex = 1 - surfaces.persistenceIndex
            surfaces.persistenceValid = true
            source = current
        } else {
            surfaces.persistenceValid = false
        }

        // 2. Bloom: threshold → half-res → separable gaussian.
        var bloomTexture: MTLTexture = surfaces.terminal // dummy when bloom off
        if uniforms.bloomStrength > 0 {
            var extract = BloomExtractUniforms(threshold: bloomThreshold)
            pass(surfaces.bloomA) { encoder in
                encoder.setRenderPipelineState(extractPipeline)
                encoder.setFragmentTexture(source, index: 0)
                encoder.setFragmentBytes(
                    &extract, length: MemoryLayout<BloomExtractUniforms>.stride, index: 0)
            }
            // Half-res sigma; the 13-tap kernel holds up to sigma ≈ 3.
            let sigma = min(max(bloomSigmaPx / 2, 0.5), 3.0)
            var horizontal = BlurUniforms(
                step: SIMD2(1 / Float(surfaces.bloomA.width), 0), sigma: sigma)
            pass(surfaces.bloomB) { encoder in
                encoder.setRenderPipelineState(blurPipeline)
                encoder.setFragmentTexture(surfaces.bloomA, index: 0)
                encoder.setFragmentBytes(
                    &horizontal, length: MemoryLayout<BlurUniforms>.stride, index: 0)
            }
            var vertical = BlurUniforms(
                step: SIMD2(0, 1 / Float(surfaces.bloomA.height)), sigma: sigma)
            pass(surfaces.bloomA) { encoder in
                encoder.setRenderPipelineState(blurPipeline)
                encoder.setFragmentTexture(surfaces.bloomB, index: 0)
                encoder.setFragmentBytes(
                    &vertical, length: MemoryLayout<BlurUniforms>.stride, index: 0)
            }
            bloomTexture = surfaces.bloomA
        }

        // 3. Composite into the output.
        var u = uniforms
        pass(output) { encoder in
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentTexture(bloomTexture, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<CRTUniforms>.stride, index: 0)
        }
    }

    private struct PersistenceUniforms {
        var decay: Float
    }

    private struct BloomExtractUniforms {
        var threshold: Float
    }

    private struct BlurUniforms {
        var step: SIMD2<Float>
        var sigma: Float
    }
}
