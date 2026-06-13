import CoreGraphics
import CoreText
import Foundation
import Testing
import TerminalCore
@testable import CRTRendering

struct EffectPipelineTests {
    private func makeRenderer() -> TerminalRenderer? {
        TerminalRenderer(font: CTFontCreateWithName("Menlo" as CFString, 12, nil), scale: 1)
    }

    private func makeTerminal(columns: Int = 20, rows: Int = 6) -> Terminal {
        var terminal = Terminal(columns: columns, rows: rows)
        terminal.feed(Array("HELLO CRT WORLD\r\n\u{1B}[31mred\u{1B}[0m \u{1B}[42mgreen\u{1B}[0m".utf8))
        return terminal
    }

    private func bytes(_ image: CGImage) -> Data {
        image.dataProvider!.data! as Data
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let data = bytes(image)
        let offset = y * image.bytesPerRow + x * 4
        return (Int(data[offset + 2]), Int(data[offset + 1]), Int(data[offset]))
    }

    private func preset(_ name: String) -> CRTPreset {
        CRTPresetLibrary.preset(named: name)!
    }

    // MARK: Composite behavior

    @Test func darkStandardMatchesPlainRender() throws {
        guard let renderer = makeRenderer() else { return } // no Metal device
        let state = makeTerminal().state
        let plain = try #require(renderer.renderImage(state))
        let standard = try #require(renderer.renderImage(state, preset: .darkStandard))
        #expect(bytes(plain) == bytes(standard))
    }

    @Test func effectsChangeTheImage() throws {
        guard let renderer = makeRenderer() else { return }
        let state = makeTerminal().state
        let plain = try #require(renderer.renderImage(state))
        for preset in CRTPresetLibrary.builtIn where preset.effects {
            let composited = try #require(renderer.renderImage(state, preset: preset))
            #expect(bytes(plain) != bytes(composited), Comment(rawValue: preset.name))
        }
    }

    @Test func compositeIsDeterministic() throws {
        guard let renderer = makeRenderer() else { return }
        let state = makeTerminal().state
        let preset = preset("Commodore 1702") // every effect enabled
        let a = try #require(renderer.renderImage(state, preset: preset, time: 0.5))
        let b = try #require(renderer.renderImage(state, preset: preset, time: 0.5))
        #expect(bytes(a) == bytes(b))
    }

    @Test func monochromePhosphorTintsEverything() throws {
        guard let renderer = makeRenderer() else { return }
        let state = makeTerminal().state
        // IBM 5151: red text, green background, white text all become green.
        let image = try #require(renderer.renderImage(state, preset: preset("IBM 5151")))
        var brightest = (r: 0, g: 0, b: 0)
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                let p = pixel(image, x, y)
                if p.g > brightest.g { brightest = p }
            }
        }
        #expect(brightest.g > 150, "expected bright green phosphor pixels")
        #expect(brightest.r < brightest.g / 2, "red must be tinted away")
    }

    @Test func curvatureDarkensCorners() throws {
        guard let renderer = makeRenderer() else { return }
        let state = makeTerminal().state
        let image = try #require(renderer.renderImage(state, preset: preset("IBM 5151")))
        let corner = pixel(image, 1, 1)
        #expect(corner.r + corner.g + corner.b < 20, "outside the tube is black")
    }

    @Test func bezelSurroundsTheScreen() throws {
        guard let renderer = makeRenderer() else { return }
        let state = makeTerminal().state
        let plain = try #require(renderer.renderImage(state))
        let preset = preset("Commodore 1702")
        let image = try #require(renderer.renderImage(state, preset: preset))
        let inset = Int(preset.bezel.widthPt) // scale 1
        #expect(image.width == plain.width + 2 * inset)
        #expect(image.height == plain.height + 2 * inset)
        // The frame area shows shaded bezel plastic, not black void.
        let corner = pixel(image, 2, 2)
        #expect(corner.r + corner.g + corner.b > 40, "bezel should be visible: \(corner)")
    }

    @Test func degaussDistortsTheImage() throws {
        guard let renderer = makeRenderer() else { return }
        let state = makeTerminal().state
        let preset = preset("DEC VT220")
        let calm = try #require(renderer.renderImage(state, preset: preset))
        let wobbling = try #require(
            renderer.renderImage(state, preset: preset, degaussPhase: 0.2))
        #expect(bytes(calm) != bytes(wobbling))
    }

    // MARK: IME marked text

    @Test func markedTextDrawsAtCursor() throws {
        guard let renderer = makeRenderer() else { return }
        var terminal = Terminal(columns: 12, rows: 2)
        terminal.feed(Array("ab".utf8))
        let plain = try #require(renderer.renderImage(terminal.state))
        let composing = try #require(
            renderer.renderImage(terminal.state, markedText: "にほ"))
        #expect(bytes(plain) != bytes(composing))
        // The composition cell shows the marked (selection-tinted)
        // background, not the block cursor's bright inverted fill.
        let cellW = Int(renderer.cellSize.width)
        let p = pixel(composing, cellW * 2 + 1, 1)
        #expect(p.b > p.r, "expected selection-tinted composition bg: \(p)")
    }

    // MARK: Effect clock (persistence decay, degauss, quiescence)

    @Test func persistenceDecayFollowsTimeConstant() throws {
        guard let renderer = makeRenderer() else { return }
        let context = SurfaceContext()
        renderer.preset = preset("IBM 5151") // decayMs 350
        let tau = 0.350

        // First frame after a preset change resets phosphor history.
        let first = renderer.beginFrame(at: 10, contentChanged: true, context: context)
        #expect(first.decayFactor == 0)
        let second = renderer.beginFrame(at: 10.1, contentChanged: false, context: context)
        #expect(abs(Double(second.decayFactor) - exp(-0.1 / tau)) < 0.001)
    }

    @Test func persistenceKeepsFramesFlowingUntilDecayed() throws {
        guard let renderer = makeRenderer() else { return }
        let context = SurfaceContext()
        renderer.preset = preset("IBM 5151")
        _ = renderer.beginFrame(at: 100, contentChanged: true, context: context)
        #expect(renderer.wantsContinuousFrames(at: 100.5, context: context))
        // 6τ later the trail is below 8-bit visibility; the loop may pause.
        #expect(!renderer.wantsContinuousFrames(at: 100 + 0.350 * 6 + 0.05, context: context))
    }

    @Test func animatedArtifactsAlwaysWantFrames() throws {
        guard let renderer = makeRenderer() else { return }
        let context = SurfaceContext()
        renderer.preset = preset("Commodore 1702") // noise + hum + jitter
        #expect(renderer.wantsContinuousFrames(at: 1_000_000, context: context))
        renderer.preset = .darkStandard
        #expect(!renderer.wantsContinuousFrames(at: 1_000_000, context: context))
    }

    @Test func degaussRunsItsCourse() throws {
        guard let renderer = makeRenderer() else { return }
        let context = SurfaceContext()
        renderer.preset = preset("DEC VT220")
        _ = renderer.beginFrame(at: 0, contentChanged: true, context: context)
        let idleTime = 100.0 // long after any persistence
        #expect(!renderer.wantsContinuousFrames(at: idleTime, context: context))

        renderer.degauss(at: idleTime)
        #expect(renderer.wantsContinuousFrames(at: idleTime + 1.0, context: context))
        let mid = renderer.beginFrame(at: idleTime + 0.75, contentChanged: false, context: context)
        #expect(abs(mid.degaussPhase - 0.5) < 0.01)
        #expect(!renderer.wantsContinuousFrames(at: idleTime + 2.0, context: context))
        let after = renderer.beginFrame(at: idleTime + 2.0, contentChanged: false, context: context)
        #expect(after.degaussPhase == 1)
    }

    @Test func magnetizationBuildsUpBetweenDegausses() throws {
        guard let renderer = makeRenderer() else { return }
        let context = SurfaceContext()
        renderer.preset = preset("DEC VT220")
        // Power-on: the first frame starts the magnetization clock.
        _ = renderer.beginFrame(at: 0, contentChanged: true, context: context)

        // Inside the 30 s dead time the coil has nothing to do: no
        // amplitude, no animation — but the clock still resets.
        #expect(renderer.degauss(at: 10) == 0)
        #expect(!renderer.wantsContinuousFrames(at: 10.5, context: context))

        // Exactly at the dead time: the minimum 10% kick.
        #expect(abs(renderer.degauss(at: 40) - 0.1) < 0.001)
        let frame = renderer.beginFrame(at: 40.1, contentChanged: false, context: context)
        #expect(abs(frame.degaussAmplitude - 0.1) < 0.001)

        // Halfway up the 5-minute ramp, then fully magnetized.
        #expect(abs(renderer.degauss(at: 40 + 30 + 150) - 0.55) < 0.001)
        #expect(renderer.degauss(at: 220 + 30 + 300) == 1)
    }

    @Test func quiescentEffectsDoNotWantFrames() throws {
        guard let renderer = makeRenderer() else { return }
        let context = SurfaceContext()
        // VT220 has no animated artifacts: after persistence decays the
        // idle-power contract must hold with effects enabled.
        renderer.preset = preset("DEC VT220")
        _ = renderer.beginFrame(at: 0, contentChanged: true, context: context)
        #expect(!renderer.wantsContinuousFrames(at: 10, context: context))
    }

    // MARK: GPU budget

    @Test func fullPipelineFitsGPUBudgetAt4K() throws {
        guard let renderer = makeRenderer() else { return }
        // A grid whose pixel size is ≈ 4K with this font/scale.
        let columns = Int(3840 / renderer.cellSize.width)
        let rows = Int(2160 / renderer.cellSize.height)
        var terminal = Terminal(columns: columns, rows: rows)
        for row in 0..<rows {
            terminal.feed(Array("\u{1B}[3\(row % 8)mLorem ipsum dolor sit amet \(row)\r\n".utf8))
        }
        let preset = preset("Commodore 1702") // heaviest: every stage active
        // Sustained run: brief one-off submissions execute at idle GPU
        // clocks; the live render loop runs warmed up like this does.
        var times: [Double] = []
        for i in 0..<30 {
            let result = try #require(renderer.renderImageMeasuringGPU(
                terminal.state, preset: preset, time: Double(i)))
            times.append(result.gpuSeconds)
        }
        let best = times.min()!
        print("CRT pipeline GPU time at \(3840)x\(2160)-class: " +
              String(format: "best=%.2fms median=%.2fms",
                     best * 1000, times.sorted()[times.count / 2] * 1000))
        // Budget is < 2 ms on Apple Silicon (PERF.md records the real
        // number); only sanity-bound CI's paravirtualized GPU.
        let isVirtualGPU = renderer.device.name.contains("Paravirtual")
        #expect(best < (isVirtualGPU ? 0.1 : 0.008), "full pipeline took \(best * 1000) ms")
    }
}
