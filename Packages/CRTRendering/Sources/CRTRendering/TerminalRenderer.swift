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

    private let commandQueue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let colorGlyphPipeline: MTLRenderPipelineState
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
                               markedText: markedText, in: buffer, to: surfaces.terminal,
                               appearance: frame.preset.appearance)
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
                               markedText: markedText, in: buffer, to: target,
                               appearance: frame.preset.appearance,
                               padPx: Int((CGFloat(frame.preset.contentInsetPt) * scale)
                                   .rounded()))
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
        preset: CRTPreset? = nil,
        time: CFTimeInterval = 0,
        degaussPhase: Float = 1
    ) -> CGImage? {
        renderImageMeasuringGPU(
            state, scrollOffset: scrollOffset, selection: selection,
            markedText: markedText, preset: preset, time: time,
            degaussPhase: degaussPhase)?.image
    }

    /// renderImage plus the command buffer's GPU duration, for the
    /// performance harness (PERF.md: full CRT pipeline < 2 ms at 4K).
    public func renderImageMeasuringGPU(
        _ state: TerminalState,
        scrollOffset: Int = 0,
        selection: Selection? = nil,
        markedText: String? = nil,
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
                           markedText: markedText, in: buffer, to: surfaces.terminal,
                           appearance: preset.appearance)
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
                           markedText: markedText, in: buffer, to: texture,
                           appearance: preset?.appearance ?? .dark)
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
    private func encodeCellPass(
        _ state: TerminalState,
        scrollOffset: Int,
        selection: Selection?,
        markedText: String? = nil,
        in buffer: MTLCommandBuffer,
        to texture: MTLTexture,
        appearance: CRTPreset.Appearance = .dark,
        padPx: Int = 0
    ) {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        // Pick the light/dark scheme for this pass while holding the lock so
        // the encode-path readers (resolveColors, emitShapedRuns) are stable.
        scheme = appearance == .light ? .light : baseScheme
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
                   !(x < shapedColumns.count && shapedColumns[x]),
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

        // The composition itself: glyphs plus a heavy underline.
        if !markedColumns.isEmpty {
            var x = markedColumns.lowerBound
            let rowY = Float(state.cursor.y) * cellH
            for (scalar, width) in markedScalars {
                guard x < markedColumns.upperBound else { break }
                if let entry = atlas.entry(forScalar: scalar.value), !entry.isEmpty {
                    let instance = GlyphInstance(
                        origin: SIMD2(
                            Float(x) * cellW + entry.bearing.x,
                            rowY + baselineOffset - entry.bearing.y),
                        size: entry.size,
                        uvOrigin: entry.uvOrigin,
                        uvSize: entry.uvSize,
                        color: scheme.foreground)
                    if entry.isColor {
                        colorGlyphInstances.append(instance)
                    } else {
                        glyphInstances.append(instance)
                    }
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
            let fg = resolveColors(cell, isCursor: false).fg
            let originX = Float(x) * cellW
            for shapedGlyph in glyphs {
                guard let entry = atlas.entry(forPrimaryGlyph: shapedGlyph.glyph),
                      !entry.isEmpty else { continue }
                glyphInstances.append(GlyphInstance(
                    origin: SIMD2(
                        originX + shapedGlyph.xOffsetPx + entry.bearing.x,
                        rowY + baselineOffset - entry.bearing.y),
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
