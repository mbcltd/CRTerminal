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
    /// The scheme used to encode the current cell pass. Switched per draw
    /// to match the active preset's appearance (light/dark); resolved from
    /// `baseScheme` under `encodeLock`, so readers in the encode path see a
    /// stable value even though panes share one renderer.
    public var scheme: ColorScheme
    /// The configured dark scheme; the base that `.dark` presets render with
    /// (light presets switch to `ColorScheme.light`).
    private let baseScheme: ColorScheme

    /// The active preset's stylised text rendering and the frame's clock,
    /// adopted at the top of `encodeCellPass` under `encodeLock` so the
    /// encode-path readers (resolveColors, the glyph emit, emitShapedRuns)
    /// see a stable value even though panes share one renderer.
    private var textEffects = CRTPreset.TextEffects()
    private var frameTime: CFTimeInterval = 0

    private let commandQueue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let colorGlyphPipeline: MTLRenderPipelineState
    private let imagePipeline: MTLRenderPipelineState
    private let atlas: GlyphAtlas
    private let ascent: CGFloat
    private let effectPipeline: EffectPipeline
    /// Reused across renderImage calls (gallery previews render at 10 Hz);
    /// fresh multi-MB private textures cost real GPU time on first touch.
    /// Guarded by `offscreenLock` (textures aren't Sendable, so this can't
    /// live in an OSAllocatedUnfairLock).
    private let offscreenLock = NSLock()
    private var offscreenCache: EffectSurfaces?

    /// Keypress→photon latency probe; samples recorded around presents.
    private let latency = OSAllocatedUnfairLock<(pendingInput: CFTimeInterval?, samples: [Double])>(
        initialState: (nil, []))

    /// CRT effect state shared between the main thread (preset changes,
    /// degauss button) and render threads (per-frame reads). One renderer
    /// serves every pane in a window, so this is per-window state; the
    /// per-surface pieces live in each pane's `SurfaceContext`. The stored
    /// preset is only a fallback — panes pass their own per draw, since
    /// sidebar sessions can each wear a different theme.
    private struct EffectsState {
        var preset: CRTPreset = .darkStandard
        var degaussStart: CFTimeInterval?
        /// Amplitude of the running degauss animation (and its sound):
        /// how much magnetization had built up when the coil fired.
        var degaussAmplitude: Float = 1
        /// When the tube was last demagnetized; nil until the first frame
        /// ("power-on"). Magnetization accrues from here.
        var magnetizedSince: CFTimeInterval?
        /// Shape operator runs through Core Text so contextual ligatures
        /// apply (profile setting; pointless for fonts without them).
        var ligatures: Bool = true
    }
    private let effectsState = OSAllocatedUnfairLock(initialState: EffectsState())

    public func setLigatures(_ enabled: Bool) {
        effectsState.withLock { $0.ligatures = enabled }
    }

    /// Characters that participate in programming ligatures: only runs of
    /// these are shaped, so prose and log noise stay on the cheap per-cell
    /// path and the shaping cache stays small.
    private static let ligatureAlphabet = Set("=<>!&|:+-*/~%?.^#_".unicodeScalars.map(\.value))

    private static func isLigatureCandidate(_ cell: Cell) -> Bool {
        ligatureAlphabet.contains(cell.glyph)
            && !cell.attributes.contains(.wide)
            && !cell.attributes.contains(.wideSpacer)
    }

    public static let degaussDuration: CFTimeInterval = 1.5

    /// Magnetization buildup: nothing to degauss for the first 30 s, then
    /// the effect grows from 10% to full strength over the next 5 minutes.
    static let degaussDeadTime: CFTimeInterval = 30
    static let degaussRampDuration: CFTimeInterval = 300

    /// 0 (freshly degaussed) ... 1 (fully magnetized).
    static func magnetization(after elapsed: CFTimeInterval) -> Float {
        guard elapsed >= degaussDeadTime else { return 0 }
        let ramp = min((elapsed - degaussDeadTime) / degaussRampDuration, 1)
        return Float(0.1 + 0.9 * ramp)
    }

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

    private struct ImageInstance {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var uvOrigin: SIMD2<Float>
        var uvSize: SIMD2<Float>
    }

    public init?(font: CTFont, scale: CGFloat, scheme: ColorScheme = .default) {
        // Monospace cell metrics from the font — computed before the atlas,
        // which needs them to synthesize exact-cell box/block glyphs.
        var glyph = CGGlyph(0)
        var advance = CGSize.zero
        var character = UniChar(0x30) // '0'
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .default, &glyph, &advance, 1)
        ascent = CTFontGetAscent(font)
        let height = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        cellSize = CGSize(width: advance.width.rounded(.up), height: height.rounded(.up))

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let atlas = GlyphAtlas(
                device: device, font: font, scale: scale,
                cellSize: cellSize, ascent: ascent),
              let effectPipeline = EffectPipeline(device: device)
        else { return nil }
        self.device = device
        self.commandQueue = queue
        self.atlas = atlas
        self.effectPipeline = effectPipeline
        self.scale = scale
        self.scheme = scheme
        self.baseScheme = scheme

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

            // Inline images: premultiplied RGBA, same blend as color glyphs.
            let imageDescriptor = MTLRenderPipelineDescriptor()
            imageDescriptor.vertexFunction = library.makeFunction(name: "image_vertex")
            imageDescriptor.fragmentFunction = library.makeFunction(name: "image_fragment")
            let imageAttachment = imageDescriptor.colorAttachments[0]!
            imageAttachment.pixelFormat = .bgra8Unorm
            imageAttachment.isBlendingEnabled = true
            imageAttachment.rgbBlendOperation = .add
            imageAttachment.alphaBlendOperation = .add
            imageAttachment.sourceRGBBlendFactor = .one
            imageAttachment.sourceAlphaBlendFactor = .one
            imageAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            imageAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            imagePipeline = try device.makeRenderPipelineState(descriptor: imageDescriptor)
        } catch {
            return nil
        }
    }

    /// Render-thread entry: draws into a drawable provided by
    /// CAMetalDisplayLink (never calls nextDrawable).
    /// `contentChanged` feeds the phosphor-persistence clock: pass false
    /// when redrawing only because an effect is animating.
    /// `context` is the pane's surface state — one per render loop, so a
    /// single renderer (and its glyph atlas) serves every pane in a window.
    public func draw(
        _ state: TerminalState,
        scrollOffset: Int = 0,
        selection: Selection? = nil,
        markedText: String? = nil,
        hoveredLink: Selection? = nil,
        searchMatches: [Selection] = [],
        currentMatch: Selection? = nil,
        contentChanged: Bool = true,
        at time: CFTimeInterval = CACurrentMediaTime(),
        preset: CRTPreset? = nil,
        context: SurfaceContext,
        into drawable: CAMetalDrawable
    ) {
        autoreleasepool {
            let target = drawable.texture
            let frame = beginFrame(
                at: time, contentChanged: contentChanged, context: context,
                preset: preset)
            let imageCache = context.imageCache ?? {
                let cache = ImageTextureCache(device: device)
                context.imageCache = cache
                return cache
            }()
            guard let buffer = commandQueue.makeCommandBuffer() else { return }
            if frame.preset.effects {
                let bezel = Int(frame.uniforms(width: target.width, height: target.height,
                                               scale: scale).bezelPx.rounded())
                let screenW = max(target.width - 2 * bezel, 1)
                let screenH = max(target.height - 2 * bezel, 1)
                if context.surfaces?.width != screenW || context.surfaces?.height != screenH {
                    context.surfaces = EffectSurfaces(
                        device: device, width: screenW, height: screenH)
                }
                guard var surfaces = context.surfaces else { return }
                encodeCellPass(state, scrollOffset: scrollOffset, selection: selection,
                               markedText: markedText, hoveredLink: hoveredLink,
                               searchMatches: searchMatches, currentMatch: currentMatch,
                               in: buffer, to: surfaces.terminal,
                               scheme: resolveScheme(for: frame.preset),
                               textEffects: frame.preset.text, time: frame.time,
                               imageCache: imageCache)
                effectPipeline.encode(
                    into: buffer, surfaces: &surfaces, output: target,
                    uniforms: frame.uniforms(width: target.width, height: target.height, scale: scale),
                    decayFactor: frame.decayFactor,
                    bloomThreshold: Float(frame.preset.bloom.threshold),
                    bloomSigmaPx: Float(frame.preset.bloom.radiusMM)
                        * CRTUniforms.pixelsPerMM(scale: scale))
                context.surfaces = surfaces
            } else {
                context.surfaces = nil // museum off: no offscreen chain at all
                // The view reserves contentInsetPt around the grid; shift
                // the cell pass to match (offscreen renderImage stays
                // unpadded — the margin is window layout, not content).
                encodeCellPass(state, scrollOffset: scrollOffset, selection: selection,
                               markedText: markedText, hoveredLink: hoveredLink,
                               searchMatches: searchMatches, currentMatch: currentMatch,
                               in: buffer, to: target,
                               scheme: resolveScheme(for: frame.preset),
                               textEffects: frame.preset.text, time: frame.time,
                               padPx: Int((CGFloat(frame.preset.contentInsetPt) * scale)
                                   .rounded()),
                               imageCache: imageCache)
            }
            attachLatencySample(to: buffer)
            buffer.present(drawable)
            buffer.commit()
        }
    }

    // MARK: CRT effects

    /// The fallback preset for panes that don't pass their own per draw.
    /// (Per-pane phosphor history resets when a pane's preset changes —
    /// `beginFrame` compares against the context's last preset.)
    public var preset: CRTPreset {
        get { effectsState.withLock { $0.preset } }
        set { effectsState.withLock { $0.preset = newValue } }
    }

    /// Fire the degauss coil. The visible wobble (and the caller's sound)
    /// scales with how much magnetization has built up since the last
    /// firing — returns that amplitude, 0 when there is nothing to degauss
    /// yet (no animation runs).
    @discardableResult
    public func degauss(at time: CFTimeInterval = CACurrentMediaTime()) -> Float {
        effectsState.withLock { state in
            let elapsed = time - (state.magnetizedSince ?? time)
            let amplitude = Self.magnetization(after: elapsed)
            // The coil fires regardless; the tube is clean either way.
            state.magnetizedSince = time
            guard amplitude > 0 else { return 0 }
            state.degaussStart = time
            state.degaussAmplitude = amplitude
            return amplitude
        }
    }

    /// True while an effect needs frames with no new terminal output:
    /// degauss running, animated artifacts (noise/hum/jitter), or this
    /// pane's phosphor persistence still visibly decaying. The render loop
    /// keeps ticking while this holds and pauses once quiescent.
    public func wantsContinuousFrames(
        at time: CFTimeInterval = CACurrentMediaTime(),
        context: SurfaceContext,
        preset panePreset: CRTPreset? = nil
    ) -> Bool {
        let (fallback, degaussStart) = effectsState.withLock { ($0.preset, $0.degaussStart) }
        let preset = panePreset ?? fallback
        // Shaking bold text animates with no new terminal output and is
        // independent of the CRT effect chain (the RPG theme runs effects off).
        if preset.text.shakes { return true }
        guard preset.effects else { return false }
        if let degaussStart, time - degaussStart < Self.degaussDuration + 0.1 { return true }
        if preset.artifacts.isAnimated { return true }
        let tau = preset.phosphor.decayMs / 1000
        // exp(-6) < 1/255: the trail has fully left 8-bit range.
        if tau > 0, time - context.lastContentChange < tau * 6 { return true }
        return false
    }

    /// Per-frame effect parameters resolved under the lock.
    struct FrameSetup {
        var preset: CRTPreset
        var degaussPhase: Float
        var degaussAmplitude: Float = 1
        var decayFactor: Float
        var time: CFTimeInterval

        func uniforms(width: Int, height: Int, scale: CGFloat) -> CRTUniforms {
            CRTUniforms(preset: preset, width: width, height: height, scale: scale,
                        time: time, degaussPhase: degaussPhase,
                        degaussAmplitude: degaussAmplitude)
        }
    }

    /// Internal for tests: the decay/degauss bookkeeping is asserted directly.
    func beginFrame(
        at time: CFTimeInterval, contentChanged: Bool, context: SurfaceContext,
        preset panePreset: CRTPreset? = nil
    ) -> FrameSetup {
        // Shared (per-window) state under the lock; per-pane clocks on the
        // context, which belongs to a single render thread.
        let (fallback, degaussStart, degaussAmplitude):
            (CRTPreset, CFTimeInterval?, Float) = effectsState.withLock { state in
            if let start = state.degaussStart,
               (time - start) / Self.degaussDuration >= 1 {
                state.degaussStart = nil
            }
            // First frame = power-on; magnetization starts accruing.
            if state.magnetizedSince == nil { state.magnetizedSince = time }
            return (state.preset, state.degaussStart, state.degaussAmplitude)
        }
        let preset = panePreset ?? fallback

        if contentChanged { context.lastContentChange = time }
        // Long gaps (paused link) decay the phosphor fully; clamp so a
        // suspend/resume doesn't compute exp() of half a day.
        let dt = min(max(time - (context.lastDrawTime ?? time), 0), 1)
        context.lastDrawTime = time

        var degaussPhase: Float = 1
        if let degaussStart {
            degaussPhase = Float(max((time - degaussStart) / Self.degaussDuration, 0))
        }

        let tau = preset.phosphor.decayMs / 1000
        var decayFactor: Float = tau > 0 ? Float(exp(-dt / tau)) : 0
        if context.lastPreset != preset {
            context.lastPreset = preset
            decayFactor = 0
        }
        return FrameSetup(
            preset: preset, degaussPhase: degaussPhase,
            degaussAmplitude: degaussAmplitude,
            decayFactor: decayFactor, time: time)
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

    /// Offscreen render with CPU readback — drives render tests, the debug
    /// probe, preset snapshot tests, and the gallery's live previews.
    /// With a preset, the full effect chain runs (deterministically for the
    /// given `time`/`degaussPhase`); persistence is single-frame, so trails
    /// only appear in the live surface.
    public func renderImage(
        _ state: TerminalState,
        scrollOffset: Int = 0,
        selection: Selection? = nil,
        markedText: String? = nil,
        searchMatches: [Selection] = [],
        currentMatch: Selection? = nil,
        preset: CRTPreset? = nil,
        time: CFTimeInterval = 0,
        degaussPhase: Float = 1
    ) -> CGImage? {
        renderImageMeasuringGPU(
            state, scrollOffset: scrollOffset, selection: selection,
            markedText: markedText, searchMatches: searchMatches,
            currentMatch: currentMatch, preset: preset, time: time,
            degaussPhase: degaussPhase)?.image
    }

    /// renderImage plus the command buffer's GPU duration, for the
    /// performance harness (PERF.md: full CRT pipeline < 2 ms at 4K).
    public func renderImageMeasuringGPU(
        _ state: TerminalState,
        scrollOffset: Int = 0,
        selection: Selection? = nil,
        markedText: String? = nil,
        searchMatches: [Selection] = [],
        currentMatch: Selection? = nil,
        preset: CRTPreset? = nil,
        time: CFTimeInterval = 0,
        degaussPhase: Float = 1
    ) -> (image: CGImage, gpuSeconds: Double)? {
        let gridWidth = max(1, Int(CGFloat(state.columns) * cellSize.width * scale))
        let gridHeight = max(1, Int(CGFloat(state.rows) * cellSize.height * scale))
        let effects = preset.map { $0.effects } ?? false
        let bezelPx = effects
            ? Int((Float(preset!.bezel.widthPt) * Float(scale)).rounded()) : 0
        let width = gridWidth + 2 * bezelPx
        let height = gridHeight + 2 * bezelPx

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = commandQueue.makeCommandBuffer() else { return nil }

        if effects, let preset {
            // The lock spans encode + commit: offscreen renders are
            // occasional (previews, probes) and must not share textures.
            offscreenLock.lock()
            defer { offscreenLock.unlock() }
            if offscreenCache?.width != gridWidth || offscreenCache?.height != gridHeight {
                offscreenCache = EffectSurfaces(
                    device: device, width: gridWidth, height: gridHeight)
            }
            guard var surfaces = offscreenCache else { return nil }
            // Each offscreen render stands alone: never inherit trails
            // from an earlier preview (the pass still runs, so GPU
            // timing matches the live chain).
            surfaces.persistenceValid = false
            encodeCellPass(state, scrollOffset: scrollOffset, selection: selection,
                           markedText: markedText, searchMatches: searchMatches,
                           currentMatch: currentMatch, in: buffer, to: surfaces.terminal,
                           scheme: resolveScheme(for: preset),
                           textEffects: preset.text, time: time,
                           imageCache: ImageTextureCache(device: device))
            effectPipeline.encode(
                into: buffer, surfaces: &surfaces, output: texture,
                uniforms: CRTUniforms(
                    preset: preset, width: width, height: height, scale: scale,
                    time: time, degaussPhase: degaussPhase),
                decayFactor: preset.phosphor.decayMs > 0 ? 1 : 0,
                bloomThreshold: Float(preset.bloom.threshold),
                bloomSigmaPx: Float(preset.bloom.radiusMM)
                    * CRTUniforms.pixelsPerMM(scale: scale))
            offscreenCache = surfaces
            buffer.commit()
            buffer.waitUntilCompleted()
        } else {
            encodeCellPass(state, scrollOffset: scrollOffset, selection: selection,
                           markedText: markedText, searchMatches: searchMatches,
                           currentMatch: currentMatch, in: buffer, to: texture,
                           scheme: resolveScheme(for: preset),
                           textEffects: preset?.text ?? CRTPreset.TextEffects(), time: time,
                           imageCache: ImageTextureCache(device: device))
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        let gpuSeconds = max(buffer.gpuEndTime - buffer.gpuStartTime, 0)

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        guard let image = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent) else { return nil }
        return (image, gpuSeconds)
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

    /// Serializes cell-pass encoding: panes share this renderer from their
    /// own render threads, and the glyph atlas caches are not concurrent.
    private let encodeLock = NSLock()

    /// `padPx` shifts the grid away from the texture edges (museum off
    /// renders straight to the drawable, which is inset-larger than the
    /// grid); the pass clears the whole texture, so the pad shows the
    /// scheme background.
    /// The terminal color scheme for a preset: an explicit palette wins;
    /// otherwise `appearance` picks the light or the (renderer-default) dark
    /// scheme.
    private func resolveScheme(for preset: CRTPreset?) -> ColorScheme {
        guard let preset else { return baseScheme }
        return ColorScheme.resolve(for: preset, darkBase: baseScheme)
    }

    /// A find-match span clipped to one viewport row, precomputed so the
    /// per-cell pass below stays O(cells): `y` is the viewport row, `start`/
    /// `end` are inclusive columns, `isCurrent` flags the emphasized match.
    private struct MatchSpan {
        var y: Int
        var start: Int
        var end: Int
        var isCurrent: Bool
    }

    /// The find matches intersecting the viewport, in (row, column) order.
    /// `matches` is the full document-ordered list (it can span the whole
    /// scrollback), so we binary-search to the first visible row rather than
    /// scanning all of it every frame.
    private func visibleMatchSpans(
        _ matches: [Selection], currentMatch: Selection?,
        viewportTop: Int, rows: Int
    ) -> [MatchSpan] {
        guard !matches.isEmpty, rows > 0 else { return [] }
        let bottom = viewportTop + rows // exclusive
        // First match whose row is at/under the viewport top.
        var lo = 0, hi = matches.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if matches[mid].start.row < viewportTop { lo = mid + 1 } else { hi = mid }
        }
        var spans: [MatchSpan] = []
        var i = lo
        while i < matches.count {
            let m = matches[i]
            let row = m.start.row
            if row >= bottom { break }
            spans.append(MatchSpan(
                y: row - viewportTop, start: m.start.column, end: m.end.column,
                isCurrent: m == currentMatch))
            i += 1
        }
        return spans
    }

    private func encodeCellPass(
        _ state: TerminalState,
        scrollOffset: Int,
        selection: Selection?,
        markedText: String? = nil,
        hoveredLink: Selection? = nil,
        searchMatches: [Selection] = [],
        currentMatch: Selection? = nil,
        in buffer: MTLCommandBuffer,
        to texture: MTLTexture,
        scheme resolvedScheme: ColorScheme = .default,
        textEffects: CRTPreset.TextEffects = CRTPreset.TextEffects(),
        time: CFTimeInterval = 0,
        padPx: Int = 0,
        imageCache: ImageTextureCache? = nil
    ) {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        // Adopt the pass's scheme while holding the lock so the encode-path
        // readers (resolveColors, emitShapedRuns) are stable. Layer the
        // terminal's runtime OSC color overrides (4/10/11/12) on top of the
        // preset scheme so program-set colors win (issue #25).
        scheme = resolvedScheme.applyingOverrides(state.colorOverrides)
        self.textEffects = textEffects
        self.frameTime = time
        let cellW = Float(cellSize.width * scale)
        let cellH = Float(cellSize.height * scale)
        let baselineOffset = Float(ascent * scale)
        let lineThickness = max(1, Float(scale))

        // RPG text styling, resolved once per pass.
        let shadowColor = textEffects.shadowColor.map {
            ColorScheme.pack($0.red, $0.green, $0.blue)
        }
        let shadowOffsetPx = Float(textEffects.shadowOffsetPt * scale)
        let shakeAmpPx = Float(textEffects.boldShakePt * scale)

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

        // Emits one glyph quad and, when the theme calls for it, a drop-shadow
        // copy behind it. `glyphX`/`baselineY` are the cell's pen origin and
        // baseline; `shake` is the per-glyph jitter already resolved (zero for
        // unstyled glyphs). Shadows are drawn only for the grayscale atlas —
        // colour (emoji) glyphs keep their own pixels — and only over a dark
        // cell: the dark shadow exists to lift text off a dark surface, so on
        // a light cell (the block cursor, a selection or search highlight,
        // inverse video) it is skipped rather than smeared black-on-light.
        func appendGlyph(
            _ entry: GlyphAtlas.Entry, glyphX: Float, baselineY: Float,
            color: UInt32, shake: SIMD2<Float> = .zero, onLightCell: Bool = false
        ) {
            let ox = glyphX + entry.bearing.x + shake.x
            let oy = baselineY - entry.bearing.y + shake.y
            if let shadowColor, !entry.isColor, !onLightCell {
                glyphInstances.append(GlyphInstance(
                    origin: SIMD2(ox + shadowOffsetPx, oy + shadowOffsetPx),
                    size: entry.size, uvOrigin: entry.uvOrigin,
                    uvSize: entry.uvSize, color: shadowColor))
            }
            let instance = GlyphInstance(
                origin: SIMD2(ox, oy), size: entry.size,
                uvOrigin: entry.uvOrigin, uvSize: entry.uvSize, color: color)
            if entry.isColor { colorGlyphInstances.append(instance) }
            else { glyphInstances.append(instance) }
        }

        // IME marked text composes over the cursor cell onward; the cells
        // underneath are masked out and the composition drawn in their place.
        var markedColumns: Range<Int> = 0..<0
        let markedScalars: [(scalar: Unicode.Scalar, width: Int)] =
            (markedText?.unicodeScalars ?? "".unicodeScalars)
                .map { ($0, CharacterWidth.width(of: $0)) }
                .filter { $0.width > 0 }
        if !markedScalars.isEmpty, offset == 0 {
            let span = markedScalars.reduce(0) { $0 + $1.width }
            markedColumns = state.cursor.x..<min(state.cursor.x + span, state.columns)
        }

        let ligatures = effectsState.withLock { $0.ligatures }

        // Find-bar highlights: every match dim, the current one bright. The
        // spans are pre-clipped to the viewport and walked with a single
        // monotonic cursor as the cell loop advances in (row, column) order,
        // so the whole pass is O(cells + visibleMatches).
        let matchSpans = visibleMatchSpans(
            searchMatches, currentMatch: currentMatch,
            viewportTop: viewportTop, rows: viewport.count)
        var spanCursor = 0

        for y in 0..<viewport.count {
            let row = viewport[y]
            // Operator runs shape first; the per-cell pass below skips the
            // columns they covered (backgrounds/decorations stay per-cell).
            var shapedColumns: [Bool] = []
            if ligatures {
                let cursorColumn = cursorVisible && state.cursorStyle == .block
                    && state.cursor.y == y && markedColumns.isEmpty
                    ? state.cursor.x : -1
                shapedColumns = emitShapedRuns(
                    row: row, rowY: Float(y) * cellH, cursorColumn: cursorColumn,
                    cellW: cellW, baselineOffset: baselineOffset,
                    into: &glyphInstances)
            }
            for x in 0..<min(state.columns, row.count) {
                // Advance the match cursor to the first span that could still
                // cover this cell (skips spans on earlier rows / left of x).
                while spanCursor < matchSpans.count {
                    let span = matchSpans[spanCursor]
                    if span.y < y || (span.y == y && x > span.end) { spanCursor += 1 }
                    else { break }
                }
                var matchBackground: UInt32?
                if spanCursor < matchSpans.count {
                    let span = matchSpans[spanCursor]
                    if span.y == y, x >= span.start, x <= span.end {
                        matchBackground = span.isCurrent
                            ? scheme.searchCurrentMatchBackground
                            : scheme.searchMatchBackground
                    }
                }

                if y == state.cursor.y, markedColumns.contains(x) {
                    bgInstances.append(BgInstance(
                        origin: SIMD2(Float(x) * cellW, Float(y) * cellH),
                        size: SIMD2(cellW, cellH),
                        color: scheme.selectionBackground))
                    continue
                }
                let cell = row[x]
                let isBlockCursor = cursorVisible && state.cursorStyle == .block
                    && state.cursor.x == x && state.cursor.y == y
                    && markedColumns.isEmpty
                let selected = selection?.contains(row: viewportTop + y, column: x) ?? false
                var (fg, bg) = resolveColors(cell, isCursor: isBlockCursor)
                // A live find takes precedence over the text selection (they
                // coincide on the current match anyway).
                if let matchBackground, !isBlockCursor {
                    bg = matchBackground
                } else if selected && !isBlockCursor {
                    bg = scheme.selectionBackground
                }

                let origin = SIMD2(Float(x) * cellW, Float(y) * cellH)
                if bg != scheme.background {
                    bgInstances.append(BgInstance(
                        origin: origin, size: SIMD2(cellW, cellH), color: bg))
                }
                // The theme can fold emoji/symbols onto lo-fi font-native glyphs.
                let glyphScalar = textEffects.replaceEmoji
                    ? (Self.glyphSubstitutions[cell.glyph] ?? cell.glyph)
                    : cell.glyph
                if cell.glyph != Cell.blank.glyph,
                   !cell.attributes.contains(.wideSpacer),
                   !(x < shapedColumns.count && shapedColumns[x]),
                   let entry = atlas.entry(forScalar: glyphScalar), !entry.isEmpty {
                    // Bold cells shake in place rather than rendering heavier.
                    var shake = SIMD2<Float>(0, 0)
                    if shakeAmpPx > 0, cell.attributes.contains(.bold) {
                        shake = shakeOffset(
                            seed: (viewportTop + y) &* 131 &+ x,
                            time: frameTime, ampPx: shakeAmpPx)
                    }
                    appendGlyph(entry, glyphX: origin.x, baselineY: origin.y + baselineOffset,
                                color: fg, shake: shake, onLightCell: Self.isLight(bg))
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
                // Links: OSC 8 hyperlinks always, plain-text URLs while
                // ⌘-hovered. A tight hairline pixel-snapped onto the baseline
                // (descenders cross it) — distinct from the looser SGR
                // underline above, which an app's own styling keeps.
                if !cell.attributes.contains(.underlined),
                   !cell.attributes.contains(.wideSpacer),
                   cell.link != 0
                    || (hoveredLink?.contains(row: viewportTop + y, column: x) ?? false) {
                    overlayInstances.append(BgInstance(
                        origin: SIMD2(origin.x, (origin.y + baselineOffset).rounded()),
                        size: SIMD2(cellSpan, lineThickness),
                        color: fg))
                }
            }
        }

        // The composition itself: glyphs plus a heavy underline.
        if !markedColumns.isEmpty {
            var x = markedColumns.lowerBound
            let rowY = Float(state.cursor.y) * cellH
            for (scalar, width) in markedScalars {
                guard x < markedColumns.upperBound else { break }
                if let entry = atlas.entry(forScalar: scalar.value), !entry.isEmpty {
                    appendGlyph(entry, glyphX: Float(x) * cellW,
                                baselineY: rowY + baselineOffset, color: scheme.foreground,
                                onLightCell: Self.isLight(scheme.selectionBackground))
                }
                x += width
            }
            overlayInstances.append(BgInstance(
                origin: SIMD2(
                    Float(markedColumns.lowerBound) * cellW,
                    rowY + baselineOffset + lineThickness),
                size: SIMD2(
                    Float(markedColumns.count) * cellW, lineThickness * 2),
                color: scheme.foreground))
        }

        // Bar/underline cursor overlays (block is drawn via cell inversion).
        if cursorVisible && state.cursorStyle != .block && markedColumns.isEmpty {
            let origin = SIMD2(Float(state.cursor.x) * cellW, Float(state.cursor.y) * cellH)
            switch state.cursorStyle {
            case .bar:
                overlayInstances.append(BgInstance(
                    origin: origin,
                    size: SIMD2(max(1, Float(scale)), cellH),
                    color: scheme.cursorColor))
            case .underline:
                overlayInstances.append(BgInstance(
                    origin: SIMD2(origin.x, origin.y + cellH - lineThickness * 2),
                    size: SIMD2(cellW, lineThickness * 2),
                    color: scheme.cursorColor))
            case .block:
                break
            }
        }

        // Inline images (kitty / sixel / iTerm2): one premultiplied-RGBA
        // texture per placement, positioned by absolute row so it scrolls with
        // the text. Negative z draws under the glyphs, ≥0 over them. Drawn into
        // the cell texture, so images get the CRT treatment like everything else.
        var underImages: [(texture: MTLTexture, instance: ImageInstance)] = []
        var overImages: [(texture: MTLTexture, instance: ImageInstance)] = []
        if let imageCache, !state.imagePlacements.isEmpty {
            imageCache.purge(keeping: Set(state.images.keys))
            let placements = state.imagePlacements
                .filter { $0.onAlternateScreen == state.isAlternateScreen }
                .sorted { $0.zIndex < $1.zIndex }
            for placement in placements {
                let screenRow = placement.row - viewportTop
                guard screenRow + placement.rows > 0, screenRow < state.rows else { continue }
                guard let image = state.images[placement.imageID],
                      let tex = imageCache.texture(for: image) else { continue }
                let pw = Float(max(1, image.pixelWidth))
                let ph = Float(max(1, image.pixelHeight))
                let sw = placement.sourceWidth > 0 ? Float(placement.sourceWidth) : pw
                let sh = placement.sourceHeight > 0 ? Float(placement.sourceHeight) : ph
                let instance = ImageInstance(
                    origin: SIMD2(Float(placement.column) * cellW, Float(screenRow) * cellH),
                    size: SIMD2(Float(placement.columns) * cellW, Float(placement.rows) * cellH),
                    uvOrigin: SIMD2(Float(placement.sourceX) / pw, Float(placement.sourceY) / ph),
                    uvSize: SIMD2(sw / pw, sh / ph))
                if placement.zIndex < 0 { underImages.append((tex, instance)) }
                else { overImages.append((tex, instance)) }
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor(scheme.background)

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        // A 1:1 pixel mapping translated by the pad: the viewport rect must
        // stay inside the render target, so shrink it symmetrically and size
        // the NDC scale to match.
        let pad = max(0, min(padPx, (texture.width - 2) / 2, (texture.height - 2) / 2))
        if pad > 0 {
            encoder.setViewport(MTLViewport(
                originX: Double(pad), originY: Double(pad),
                width: Double(texture.width - 2 * pad),
                height: Double(texture.height - 2 * pad),
                znear: 0, zfar: 1))
        }
        var uniforms = Uniforms(viewport: SIMD2(
            Float(texture.width - 2 * pad), Float(texture.height - 2 * pad)))

        func drawImages(_ images: [(texture: MTLTexture, instance: ImageInstance)]) {
            guard !images.isEmpty else { return }
            encoder.setRenderPipelineState(imagePipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            for image in images {
                var instance = image.instance
                encoder.setVertexBytes(
                    &instance, length: MemoryLayout<ImageInstance>.stride, index: 0)
                encoder.setFragmentTexture(image.texture, index: 0)
                encoder.drawPrimitives(
                    type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
            }
        }

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
        drawImages(underImages)
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
        drawImages(overImages)
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
    }

    /// Finds maximal same-style runs of ligature-alphabet cells, shapes
    /// them through the atlas (Core Text applies the font's contextual
    /// alternates), and appends the shaped glyphs. Runs break at style
    /// changes and at a block cursor, which must keep its own cell glyph
    /// to invert cleanly. Returns a column mask of what was covered; a
    /// failed shape leaves its columns unmasked for the per-cell pass.
    private func emitShapedRuns(
        row: [Cell], rowY: Float, cursorColumn: Int,
        cellW: Float, baselineOffset: Float,
        into glyphInstances: inout [GlyphInstance]
    ) -> [Bool] {
        var shaped = [Bool](repeating: false, count: row.count)
        var x = 0
        while x < row.count {
            let cell = row[x]
            guard Self.isLigatureCandidate(cell), x != cursorColumn else {
                x += 1
                continue
            }
            var end = x + 1
            while end < row.count, end != cursorColumn,
                  Self.isLigatureCandidate(row[end]),
                  row[end].foreground == cell.foreground,
                  row[end].background == cell.background,
                  row[end].attributes == cell.attributes {
                end += 1
            }
            defer { x = end }
            guard end - x >= 2 else { continue }
            var text = ""
            for column in x..<end {
                guard let scalar = Unicode.Scalar(row[column].glyph) else { break }
                text.unicodeScalars.append(scalar)
            }
            guard text.count == end - x,
                  let glyphs = atlas.shape(text), !glyphs.isEmpty else { continue }
            let (fg, runBackground) = resolveColors(cell, isCursor: false)
            let originX = Float(x) * cellW
            // Skip the shadow over a light run background, matching the
            // per-cell pass — the dark shadow only reads on a dark surface.
            let shadowColor = Self.isLight(runBackground) ? nil : textEffects.shadowColor.map {
                ColorScheme.pack($0.red, $0.green, $0.blue)
            }
            let shadowOffsetPx = Float(textEffects.shadowOffsetPt * scale)
            for shapedGlyph in glyphs {
                guard let entry = atlas.entry(forPrimaryGlyph: shapedGlyph.glyph),
                      !entry.isEmpty else { continue }
                let ox = originX + shapedGlyph.xOffsetPx + entry.bearing.x
                let oy = rowY + baselineOffset - entry.bearing.y
                if let shadowColor {
                    glyphInstances.append(GlyphInstance(
                        origin: SIMD2(ox + shadowOffsetPx, oy + shadowOffsetPx),
                        size: entry.size, uvOrigin: entry.uvOrigin,
                        uvSize: entry.uvSize, color: shadowColor))
                }
                glyphInstances.append(GlyphInstance(
                    origin: SIMD2(ox, oy),
                    size: entry.size,
                    uvOrigin: entry.uvOrigin,
                    uvSize: entry.uvSize,
                    color: fg))
            }
            for column in x..<end { shaped[column] = true }
        }
        return shaped
    }

    private func resolveColors(_ cell: Cell, isCursor: Bool) -> (fg: UInt32, bg: UInt32) {
        let attrs = cell.attributes
        var fg = scheme.resolve(cell.foreground, isForeground: true, bold: attrs.contains(.bold))
        var bg = scheme.resolve(cell.background, isForeground: false, bold: false)
        if attrs.contains(.inverse) != isCursor { // inverse XOR block cursor
            swap(&fg, &bg)
            // The block cursor fills with the cursor color (foreground by
            // default, recolored by OSC 12); the glyph keeps the cell's
            // background so text reads as a cut-out (issue #25).
            if isCursor { bg = scheme.cursorColor }
        }
        if attrs.contains(.hidden) {
            fg = bg
        }
        if attrs.contains(.faint) {
            fg = Self.dim(fg)
        }
        // The RPG theme paints bold as a flat accent colour instead of
        // brightening — applied last so it wins, but never over a hidden cell
        // (its text must stay invisible) or the inverted block cursor cut-out.
        if let boldColor = textEffects.boldColor,
           attrs.contains(.bold), !attrs.contains(.hidden), !isCursor {
            fg = ColorScheme.pack(boldColor.red, boldColor.green, boldColor.blue)
        }
        return (fg, bg)
    }

    /// Choppy, pixel-snapped per-glyph jitter that re-rolls ~`fps` times a
    /// second — the JRPG "shaking bold text" wobble. Deterministic in
    /// (`seed`, time) so neighbouring glyphs shake independently but a single
    /// glyph is steady within each ~1/fps step.
    private func shakeOffset(
        seed: Int, time: CFTimeInterval, ampPx: Float, fps: Double = 13
    ) -> SIMD2<Float> {
        let f = (time * fps).rounded(.down)
        let a = sin(Double(seed) * 12.9898 + f * 78.233) * 43758.5453
        let b = sin(Double(seed) * 39.346 + f * 11.135) * 24634.6331
        let rx = Float(a - a.rounded(.down))
        let ry = Float(b - b.rounded(.down))
        return SIMD2(((rx * 2 - 1) * ampPx).rounded(), ((ry * 2 - 1) * ampPx).rounded())
    }

    /// Glyphs the RPG theme folds onto PressStart2P-native characters, keeping
    /// everything 8-bit and lo-fi. The pixel face has no colour emoji and lacks
    /// most symbol glyphs, so anything it is missing would otherwise resolve to
    /// a metrics-foreign system fallback — the thin, oversized ○ that prompted
    /// this. Every *target* below is confirmed present in PressStart2P (█ is
    /// drawn by BoxDrawing); keys are only glyphs the face lacks, so the symbols
    /// it does have (• ← → ↑ ↓ ▲ ▶ ▼ ◀ ★ ♥ ♦ ♪ « ») pass through untouched.
    /// Applied when `replaceEmoji` is set; presentation selectors (U+FE0F) and
    /// skin-tone modifiers sit in their own cells and fall away.
    static let glyphSubstitutions: [UInt32: UInt32] = {
        var map: [UInt32: UInt32] = [:]
        func fold(_ sources: [UInt32], to target: UInt32) {
            for s in sources { map[s] = target }
        }

        // Targets — all confirmed in PressStart2P's cmap.
        let bullet: UInt32 = 0x2022     // •
        let right: UInt32 = 0x2192      // →
        let left: UInt32 = 0x2190       // ←
        let up: UInt32 = 0x2191         // ↑
        let down: UInt32 = 0x2193       // ↓
        let triRight: UInt32 = 0x25B6   // ▶
        let triLeft: UInt32 = 0x25C0    // ◀
        let triUp: UInt32 = 0x25B2      // ▲
        let triDown: UInt32 = 0x25BC    // ▼
        let heart: UInt32 = 0x2665      // ♥
        let diamond: UInt32 = 0x2666    // ♦
        let star: UInt32 = 0x2605       // ★
        let check: UInt32 = 0x221A      // √  (the closest native tick)
        let cross: UInt32 = 0x00D7      // ×
        let block: UInt32 = 0x2588      // █  (BoxDrawing renders this crisply)

        // Round bullets / dots → •  (filled, outline, fisheye, the lot).
        // 0x23FA ⏺ is the record-circle TUIs (Claude Code's own) use as a bullet.
        fold([0x25CF, 0x25CB, 0x25E6, 0x25C9, 0x25CE, 0x25CC, 0x25CD, 0x25D8,
              0x25D9, 0x2B24, 0x29BF, 0x2218, 0x2219, 0x26AB, 0x26AA, 0x23FA,
              0x1F534, 0x1F7E0, 0x1F7E1, 0x1F7E2, 0x1F535, 0x1F7E3, 0x1F7E4,
              0x1F7E3, 0x1F518], to: bullet)

        // Arrow variants → the four native arrows (heavy, double, hooked, …).
        fold([0x21D2, 0x27F6, 0x27A1, 0x2794, 0x2799, 0x279C, 0x279D, 0x279E,
              0x279F, 0x21A6, 0x21AA, 0x21E8, 0x2B95, 0x2B62, 0x276F, 0x21FE], to: right)
        fold([0x21D0, 0x27F5, 0x2B05, 0x21A9, 0x21E6, 0x2B60, 0x276E, 0x21FD], to: left)
        fold([0x21D1, 0x2B06, 0x21E7, 0x2B61], to: up)
        fold([0x21D3, 0x2B07, 0x21E9, 0x2B63], to: down)
        // Small + media-control directional triangles → the full-size ones the
        // face ships. 0x23F4–0x23F7 (⏴⏵⏶⏷) are the media triangles TUIs use for
        // cues like Claude Code's "⏵⏵ accept edits" indicator.
        fold([0x25B8, 0x25B9, 0x23F5], to: triRight)
        fold([0x25C2, 0x25C3, 0x23F4], to: triLeft)
        fold([0x25B4, 0x25B5, 0x23F6], to: triUp)
        fold([0x25BE, 0x25BF, 0x23F7], to: triDown)

        // Hearts of every hue → ♥
        fold([0x2764, 0x1F495, 0x1F496, 0x1F497, 0x1F498, 0x1F499, 0x1F49A,
              0x1F49B, 0x1F49C, 0x1F49D, 0x1F49F, 0x1F493, 0x1F90D, 0x1F90E,
              0x1F5A4], to: heart)
        // Stars / sparkles / celebration → ★
        fold([0x2726, 0x2727, 0x2728, 0x2729, 0x272A, 0x272B, 0x272C, 0x272D,
              0x272E, 0x272F, 0x2730, 0x2B50, 0x26A1, 0x1F31F, 0x1F320, 0x1F4AB,
              0x1F389, 0x1F38A, 0x1F387, 0x1F386], to: star)
        // Gems → ♦
        fold([0x25C6, 0x25C7, 0x2B25, 0x2B26, 0x1F48E, 0x1F537, 0x1F536,
              0x1F539, 0x1F538], to: diamond)
        // Fire / launch / warning → ▲
        fold([0x1F525, 0x1F680, 0x26A0], to: triUp)
        // Checks → √, crosses → ×
        fold([0x2713, 0x2714, 0x2705, 0x2611, 0x1F44D, 0x1F197], to: check)
        fold([0x2717, 0x2718, 0x2716, 0x2715, 0x2612, 0x274C, 0x1F44E,
              0x1F6AB], to: cross)
        // Squares (geometric + coloured emoji) → █
        fold([0x25A0, 0x25A1, 0x25AA, 0x25AB, 0x25FC, 0x25FB, 0x25FE, 0x25FD,
              0x2B1B, 0x2B1C, 0x1F7E5, 0x1F7E7, 0x1F7E8, 0x1F7E9, 0x1F7E6,
              0x1F7EA, 0x1F7EB], to: block)
        // 0x23BF ⎿ (the result-branch connector TUIs draw) → └ U+2514, which
        // BoxDrawing renders crisply on-grid.
        fold([0x23BF], to: 0x2514)
        return map
    }()

    /// Whether a packed cell background reads as light — Rec. 601 luma over a
    /// mid threshold. Drives whether a glyph's dark drop shadow is drawn (it
    /// only reads on a dark cell). The threshold sits a touch above mid so a
    /// medium tube/palette background still counts as dark and keeps its
    /// shadow, while the cursor/selection/inverse white surfaces drop it.
    static func isLight(_ packed: UInt32) -> Bool {
        let r = Double((packed >> 24) & 0xFF)
        let g = Double((packed >> 16) & 0xFF)
        let b = Double((packed >> 8) & 0xFF)
        return 0.299 * r + 0.587 * g + 0.114 * b > 140
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
