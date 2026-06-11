import AppKit
import CRTRendering
import ImageIO
import TerminalCore
import UniformTypeIdentifiers

/// Debug-only end-to-end probe (CRT_TYPIST=1): types a command through the
/// real input path, measures input→present latency, dumps the grid as text,
/// writes a PNG of the framebuffer, and exits. Seed of the Phase 3 latency
/// harness; numbers are recorded in PERF.md.
///
/// CRT_TYPIST_SCRIPT overrides the typed bytes (pass real control chars,
/// e.g. `$'htop\rq'` from a shell); CRT_TYPIST_WAIT sets the seconds to let
/// the screen settle before the report (default 1).
final class TypistProbe {
    private weak var view: TerminalView?
    private let session: TerminalSession
    private let script: [UInt8]
    private let settleSeconds: Double
    private var position = 0

    init(view: TerminalView, session: TerminalSession) {
        self.view = view
        self.session = session
        let environment = ProcessInfo.processInfo.environment
        script = Array((environment["CRT_TYPIST_SCRIPT"] ?? "echo Phase1_é_$((6*7))\r").utf8)
        settleSeconds = Double(environment["CRT_TYPIST_WAIT"] ?? "") ?? 1.0
    }

    func start() {
        // Give the shell a moment to print its prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.typeNext()
        }
    }

    private func typeNext() {
        guard position < script.count else {
            DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) {
                self.finish()
            }
            return
        }
        let byte = script[position]
        position += 1
        // 0x1F (unit separator) in the script = pause 1s (waiting for a TUI
        // to start up). NUL can't be the marker: env values are NUL-terminated.
        let delay: Double
        if byte == 0x1F {
            delay = 1.0
        } else {
            view?.send([byte])
            delay = 0.05
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.typeNext()
        }
    }

    private func finish() {
        // Idle assertion: with no output arriving, the render loop must stop
        // producing frames and pause its display link.
        let drawsBeforeIdle = view?.drawCount ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.report(drawsBeforeIdle: drawsBeforeIdle)
        }
    }

    private func physicalFootprintMB() -> Int {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return -1 }
        return Int(info.ri_phys_footprint / 1_000_000)
    }

    private func report(drawsBeforeIdle: Int) {
        var report = ["=== CRT_TYPIST REPORT ==="]
        let drawsNow = view?.drawCount ?? 0
        let paused = view?.renderLoop?.isPaused ?? false
        report.append(
            "idle: \(drawsNow - drawsBeforeIdle) draws in 2s quiet, link paused: \(paused)")
        report.append("memory: \(physicalFootprintMB()) MB physical footprint")

        let state = session.snapshot
        report.append("grid \(state.columns)x\(state.rows), generation \(state.generation), frames drawn \(view?.drawCount ?? -1)")
        for y in 0..<state.rows {
            let text = state.lineText(y)
            if !text.isEmpty {
                report.append("row \(y): \(text)")
            }
        }

        if let samples = view?.renderer?.takeLatencySamples(), !samples.isEmpty {
            let ms = samples.map { $0 * 1000 }.sorted()
            let median = ms[ms.count / 2]
            report.append(String(
                format: "latency input→present: n=%d median=%.2fms min=%.2fms max=%.2fms",
                ms.count, median, ms.first!, ms.last!))
        } else {
            report.append("latency: no samples collected")
        }

        if let renderer = view?.renderer,
           let image = renderer.renderImage(state),
           let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: "/tmp/crterminal-probe.png") as CFURL,
            UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            report.append("frame: /tmp/crterminal-probe.png")
        }

        report.append("=== END REPORT ===")
        let text = report.joined(separator: "\n") + "\n"
        FileHandle.standardError.write(text.data(using: .utf8)!)
        // Also to a file: launching via `open` (needed for window display
        // passes) detaches stderr.
        try? text.write(
            toFile: "/tmp/crterminal-probe.txt", atomically: true, encoding: .utf8)
        exit(0)
    }
}
