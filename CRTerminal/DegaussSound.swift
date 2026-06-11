import AVFoundation

/// The authentic degauss *thunk-hummmm*, synthesized so we ship no
/// recorded sample of unclear provenance (ARCHITECTURE.md licensing risk):
/// a relay click, a low solenoid thump, and a mains-frequency coil hum
/// that rings down over the animation.
final class DegaussSound {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var started = false

    func play() {
        if buffer == nil {
            buffer = Self.synthesize()
        }
        guard let buffer else { return }
        if !started {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            guard (try? engine.start()) != nil else { return }
            started = true
        }
        player.stop()
        player.scheduleBuffer(buffer, at: nil)
        player.play()
    }

    private static func synthesize() -> AVAudioPCMBuffer? {
        let sampleRate = 44_100.0
        let duration = 1.5
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frames

        // Deterministic cheap noise for the relay click.
        var noiseState: UInt32 = 0x12345678
        func noise() -> Float {
            noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: noiseState)) / Float(Int32.max)
        }

        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            var sample = 0.0

            // Relay click: a few ms of filtered noise right at the start.
            if t < 0.008 {
                sample += Double(noise()) * 0.5 * (1.0 - t / 0.008)
            }
            // Solenoid thump: a 55 Hz sine dropping to 38 Hz, fast decay.
            let thumpFreq = 55.0 - 17.0 * min(t / 0.12, 1.0)
            sample += 0.9 * exp(-t / 0.07) * sin(2.0 * .pi * thumpFreq * t)
            // Coil hum: 60 Hz fundamental plus harmonics — the hummmm.
            // Swells in over ~30 ms, rings down with the degauss envelope.
            let humEnvelope = min(t / 0.03, 1.0) * exp(-t / 0.42)
            let hum = 0.32 * sin(2.0 * .pi * 120.0 * t)
                + 0.14 * sin(2.0 * .pi * 180.0 * t)
                + 0.10 * sin(2.0 * .pi * 60.0 * t)
            sample += humEnvelope * 0.55 * hum
            // Gentle fade so the tail doesn't click.
            let fade = min(1.0, (duration - t) / 0.1)

            samples[i] = Float(tanh(sample) * fade)
        }
        return buffer
    }
}
