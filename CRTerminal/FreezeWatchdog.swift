import Foundation
import QuartzCore
import os

/// Watches for the ways a terminal can "freeze" and leaves evidence behind
/// (ARCHITECTURE.md "Freeze diagnostics"). Once a second, on its own queue,
/// it checks:
/// - the main thread — a ping it posts must come back; a stall is logged
///   with a backtrace of the main thread;
/// - each pane — a draw that never finishes (backtrace of its render
///   thread), or output the parser produced that no frame has shown;
/// - each session — a parse holding the terminal lock (backtrace of the
///   PTY reader), or input the program has stopped reading.
/// Incidents go to the unified log (subsystem `mbcltd.crterminal`, category
/// `freeze`) at error level so they persist, into an in-memory event list,
/// and — at most every few minutes — into a report file in
/// ~/Library/Logs/crterm. Help ▸ Save Diagnostic Report writes one on demand.
nonisolated final class FreezeWatchdog: @unchecked Sendable {
    static let shared = FreezeWatchdog()
    static let log = Logger(subsystem: "mbcltd.crterminal", category: "freeze")

    enum Kind: String {
        case mainThread = "main thread unresponsive"
        case drawStuck = "render thread stuck in a draw"
        case undrawnOutput = "output not drawn"
        case parserStuck = "parser holding the terminal lock"
        case inputBlocked = "input not being read"
    }

    /// How long each condition must last before it counts as a freeze.
    static func threshold(for kind: Kind) -> CFTimeInterval {
        switch kind {
        case .mainThread, .drawStuck, .undrawnOutput, .parserStuck: 2
        // A busy program ignoring typed-ahead input for a moment is normal.
        case .inputBlocked: 5
        }
    }

    /// A main-thread ping slower than this is logged as a hitch.
    static let slowPing: CFTimeInterval = 0.25
    static let maxEvents = 200
    /// Minimum gap between automatic report files, and how many to keep.
    static let reportFileInterval: CFTimeInterval = 300
    static let maxReportFiles = 20

    struct Event {
        var date: Date
        var message: String
        var backtrace: [String] = []
    }

    private struct Pane {
        let number: Int
        weak var loop: RenderLoop?
    }

    private struct IncidentKey: Hashable {
        /// 0 is the app itself (the main thread).
        var pane: Int
        var kind: Kind
    }

    private struct State {
        var panes: [Pane] = []
        var nextPaneNumber = 1
        var incidents = IncidentTracker<IncidentKey>()
        /// When each pane was first seen with output pending and no recent
        /// frame; the undrawn-output condition runs from there.
        var undrawnSince: [Int: CFTimeInterval] = [:]
        var events: [Event] = []
        var mainThread: thread_t = 0
        var pingSentAt: CFTimeInterval?
        var slowestPing: CFTimeInterval = 0
        var hitches = 0
        var lastReportFileAt: CFTimeInterval?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let queue = DispatchQueue(label: "crterminal.watchdog", qos: .utility)
    private let timer: DispatchSourceTimer
    private let launchedAt = Date()

    private init() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
    }

    /// Starts watching. Call once, from the main thread: that's the thread
    /// the main-thread check samples.
    func start() {
        let main = pthread_mach_thread_np(pthread_self())
        let first = state.withLockUnchecked { state in
            defer { state.mainThread = main }
            return state.mainThread == 0
        }
        if first { timer.resume() }
    }

    /// Render loops sign themselves up; held weakly, pruned once gone.
    func register(_ loop: RenderLoop) {
        state.withLockUnchecked { state in
            state.panes.removeAll { $0.loop == nil }
            state.panes.append(Pane(number: state.nextPaneNumber, loop: loop))
            state.nextPaneNumber += 1
        }
    }

    // MARK: Checks

    private func tick() {
        let now = CACurrentMediaTime()
        let (main, pingSentAt, panes) = state.withLockUnchecked { state in
            state.panes.removeAll { $0.loop == nil }
            return (state.mainThread, state.pingSentAt,
                    state.panes.compactMap { pane in pane.loop.map { (pane.number, $0) } })
        }
        track(IncidentKey(pane: 0, kind: .mainThread), since: pingSentAt, now: now) {
            ("", Self.backtrace(of: main))
        }
        if pingSentAt == nil { ping(sentAt: now) }
        for (number, loop) in panes {
            check(pane: number, loop: loop, now: now)
        }
    }

    /// The ping is answered whenever the main queue drains, which the main
    /// run loop does in every mode (menus and modal alerts included).
    private func ping(sentAt: CFTimeInterval) {
        state.withLockUnchecked { $0.pingSentAt = sentAt }
        DispatchQueue.main.async { [self] in
            let latency = CACurrentMediaTime() - sentAt
            state.withLockUnchecked { state in
                state.pingSentAt = nil
                state.slowestPing = max(state.slowestPing, latency)
                if latency >= Self.slowPing { state.hitches += 1 }
            }
            if latency >= Self.slowPing {
                Self.log.notice("main thread busy for \(Int(latency * 1000)) ms")
            }
        }
    }

    private func check(pane number: Int, loop: RenderLoop, now: CFTimeInterval) {
        let render = loop.health
        let session = loop.terminalSession?.health
        let invalidated = render.invalidated
        let draw = invalidated ? nil : render.drawStartedAt
        track(IncidentKey(pane: number, kind: .drawStuck), since: draw, now: now) {
            (Self.identity(of: session), Self.backtrace(of: render.renderThread))
        }

        let undrawn = !invalidated && Self.hasUndrawnOutput(
            render, displayGeneration: session?.terminal?.displayGeneration, now: now)
        let undrawnSince = state.withLockUnchecked { state -> CFTimeInterval? in
            // A frame drawn since we first noticed means it isn't stuck.
            guard undrawn else {
                state.undrawnSince[number] = nil
                return nil
            }
            if let seen = state.undrawnSince[number], (render.lastDrawAt ?? 0) < seen {
                return seen
            }
            state.undrawnSince[number] = now
            return now
        }
        track(IncidentKey(pane: number, kind: .undrawnOutput), since: undrawnSince, now: now) {
            ("\(Self.identity(of: session)); \(Self.describe(render, session: session, now: now))", [])
        }

        let feed = invalidated ? nil : session?.feedStartedAt
        track(IncidentKey(pane: number, kind: .parserStuck), since: feed, now: now) {
            (Self.identity(of: session), Self.backtrace(of: session?.io.readerThread ?? 0))
        }

        let blocked = invalidated ? nil : session?.io.writeBlockedSince
        track(IncidentKey(pane: number, kind: .inputBlocked), since: blocked, now: now) {
            let queued = Self.bytes(session?.io.queuedWriteBytes ?? 0)
            return ("\(Self.identity(of: session)); \(queued) queued — the foreground "
                    + "program isn't reading its terminal", [])
        }
    }

    /// Output the renderer should show but hasn't: the pane is on screen,
    /// the display generation is past the last one drawn, and no frame has
    /// gone out for a second — the link would have drawn it within one
    /// refresh had it been awake.
    static func hasUndrawnOutput(
        _ render: RenderLoop.Health, displayGeneration: UInt64?, now: CFTimeInterval
    ) -> Bool {
        guard !render.occluded, !render.invalidated, render.windowVisible,
              let displayGeneration, displayGeneration != render.lastDrawnGeneration
        else { return false }
        return now - (render.lastDrawAt ?? render.createdAt) >= 1
    }

    /// Feeds one condition through the tracker; logs when it has lasted its
    /// threshold (with `detail` — context plus an optional backtrace, only
    /// computed then) and again when it clears.
    private func track(
        _ key: IncidentKey, since: CFTimeInterval?, now: CFTimeInterval,
        detail: () -> (context: String, backtrace: [String])
    ) {
        let transition = state.withLockUnchecked { state in
            state.incidents.update(
                key, since: since, now: now, threshold: Self.threshold(for: key.kind))
        }
        let subject = key.pane == 0 ? key.kind.rawValue : "pane \(key.pane): \(key.kind.rawValue)"
        switch transition {
        case .none:
            break
        case .began(let elapsed):
            let (context, backtrace) = detail()
            let message = "\(subject) for \(Self.seconds(elapsed))"
                + (context.isEmpty ? "" : " — \(context)")
            record(message, backtrace: backtrace, severity: .error)
            writeReportFileIfDue(now: now)
        case .ended(let lasted):
            record("\(subject): cleared after ~\(Self.seconds(lasted))", severity: .default)
        }
    }

    private func record(_ message: String, backtrace: [String] = [], severity: OSLogType) {
        Self.log.log(level: severity, "\(message, privacy: .public)")
        // Long log messages get truncated; send the stack in slices.
        for start in stride(from: 0, to: backtrace.count, by: 16) {
            let slice = backtrace[start..<min(start + 16, backtrace.count)]
            Self.log.log(level: severity, "\(slice.joined(separator: "\n"), privacy: .public)")
        }
        state.withLockUnchecked { state in
            state.events.append(Event(date: Date(), message: message, backtrace: backtrace))
            if state.events.count > Self.maxEvents {
                state.events.removeFirst(state.events.count - Self.maxEvents)
            }
        }
    }

    private static func backtrace(of thread: thread_t) -> [String] {
        ThreadBacktrace.symbolicate(ThreadBacktrace.capture(thread))
    }

    // MARK: Report

    /// A plain-text snapshot of every pane's health plus the recent events.
    /// Safe from any thread; `extraSections` lets the main thread add what
    /// only it can see (window and session names).
    func report(extraSections: [String] = []) -> String {
        let now = CACurrentMediaTime()
        let (panes, events, slowestPing, hitches) = state.withLockUnchecked { state in
            (state.panes.compactMap { pane in pane.loop.map { (pane.number, $0) } },
             state.events, state.slowestPing, state.hitches)
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "crterm \(version) (\(build)) diagnostic report",
            "Generated \(Self.timestamp(Date())), up \(Self.seconds(Date().timeIntervalSince(launchedAt)))",
            "\(ProcessInfo.processInfo.operatingSystemVersionString), executable UUID "
                + (ThreadBacktrace.executableUUID ?? "?"),
            "Main thread: slowest ping \(Int(slowestPing * 1000)) ms, "
                + "\(hitches) pings ≥ \(Int(Self.slowPing * 1000)) ms",
        ]
        lines += extraSections
        let open = panes.map { ($0.0, $0.1.health, $0.1.terminalSession?.health) }
            .filter { !$0.1.invalidated }
        lines.append("")
        lines.append("Panes (\(open.count)):")
        for (number, render, session) in open {
            lines.append("  Pane \(number) — \(Self.identity(of: session))")
            lines.append("    \(Self.describe(render, session: session, now: now))")
            guard let session else { continue }
            var pty = "pty: \(Self.bytes(Int(clamping: session.io.bytesRead))) read"
            if let read = session.io.lastReadAt { pty += ", last \(Self.seconds(now - read)) ago" }
            pty += "; \(Self.bytes(session.io.queuedWriteBytes)) input queued"
            if let blocked = session.io.writeBlockedSince {
                pty += ", blocked \(Self.seconds(now - blocked))"
            }
            lines.append("    \(pty)")
            var parser = session.feedStartedAt.map { "parser: busy \(Self.seconds(now - $0))" }
                ?? "parser: idle"
            parser += "; slowest batch \(Int(session.slowestFeed * 1000)) ms"
            parser += "; \(session.synchronizedOutputExpiries) ?2026 timeouts"
            lines.append("    \(parser)")
        }
        lines.append("")
        lines.append("Events (\(events.count), oldest first):")
        for event in events {
            lines.append("  \(Self.timestamp(event.date))  \(event.message)")
            lines += event.backtrace.map { "      \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "zsh (pid 4242) running claude (pgid 4250), 120×40, alternate screen"
    private static func identity(of session: TerminalSession.Health?) -> String {
        guard let session else { return "session gone" }
        let shell = session.shellProcessID
        var text = "\(session.commandName ?? SessionInfo.processName(of: shell) ?? "?") (pid \(shell))"
        if let status = session.exitStatus {
            text += ", exited (\(TerminalSession.exitDescription(status: status)))"
        } else if session.foregroundProcessGroup > 0, session.foregroundProcessGroup != shell {
            let group = session.foregroundProcessGroup
            text += " running \(SessionInfo.processName(of: group) ?? "?") (pgid \(group))"
        }
        guard let screen = session.terminal else { return text + ", terminal lock busy" }
        text += ", \(screen.columns)×\(screen.rows), \(screen.scrollbackLines) scrollback"
        if screen.alternateScreen { text += ", alternate screen" }
        if screen.synchronizedOutput { text += ", ?2026 active" }
        return text
    }

    private static func describe(
        _ render: RenderLoop.Health, session: TerminalSession.Health?, now: CFTimeInterval
    ) -> String {
        var parts: [String] = []
        parts.append(render.occluded ? "hidden tab"
            : render.windowVisible ? "on screen" : "window not visible")
        parts.append(render.linkPaused ? "link paused" : "link running")
        var frames = "\(render.drawCount) frames"
        if let last = render.lastDrawAt { frames += ", last \(seconds(now - last)) ago" }
        parts.append(frames)
        if let started = render.drawStartedAt {
            parts.append("drawing for \(seconds(now - started))")
        }
        let drawn = render.lastDrawnGeneration.map(String.init) ?? "none"
        let current = session?.terminal.map { String($0.displayGeneration) } ?? "?"
        parts.append("generation drawn \(drawn) of \(current)")
        return "render: " + parts.joined(separator: ", ")
    }

    // MARK: Report files

    /// ~/Library/Logs/crterm — or a scratch directory for tests and probes,
    /// so they never litter the user's logs.
    static var reportsDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        let temporary = FileManager.default.temporaryDirectory
        if environment["CRT_CLEAN_LAUNCH"] != nil
            || environment["XCTestConfigurationFilePath"] != nil {
            return temporary.appendingPathComponent("CRTerminalCleanLaunch/Logs", isDirectory: true)
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? temporary
        return library.appendingPathComponent("Logs/crterm", isDirectory: true)
    }

    /// Writes `report()` to `<prefix>-<timestamp>.txt` in the reports
    /// directory; returns the file, or nil if it couldn't be written.
    @discardableResult
    func writeReport(prefix: String, extraSections: [String] = []) -> URL? {
        let directory = Self.reportsDirectory
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent(
            "\(prefix)-\(formatter.string(from: Date())).txt")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try report(extraSections: extraSections).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Self.log.error("writing diagnostic report failed: \(error, privacy: .public)")
            return nil
        }
        pruneReports(prefix: prefix, in: directory)
        return url
    }

    private func writeReportFileIfDue(now: CFTimeInterval) {
        let due = state.withLockUnchecked { state in
            if let last = state.lastReportFileAt, now - last < Self.reportFileInterval {
                return false
            }
            state.lastReportFileAt = now
            return true
        }
        guard due, let url = writeReport(prefix: "freeze") else { return }
        Self.log.error("freeze report written to \(url.path, privacy: .public)")
    }

    /// Keeps the newest `maxReportFiles` with this prefix (names sort by time).
    private func pruneReports(prefix: String, in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let reports = names.filter { $0.hasPrefix(prefix + "-") && $0.hasSuffix(".txt") }.sorted()
        for name in reports.dropLast(Self.maxReportFiles) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Formatting

    private static func seconds(_ interval: TimeInterval) -> String {
        if interval < 60 { return String(format: "%.1f s", interval) }
        let minutes = Int(interval / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return formatter.string(from: date)
    }
}

/// The freeze watchdog's timing rules, kept pure so they're testable: which
/// conditions are ongoing, since when, and whether they've been reported.
nonisolated struct IncidentTracker<Key: Hashable> {
    enum Transition: Equatable {
        case none
        /// The condition has now lasted `elapsed` ≥ its threshold.
        case began(elapsed: CFTimeInterval)
        /// A reported condition cleared, having lasted about `lasted`.
        case ended(lasted: CFTimeInterval)
    }

    private var ongoing: [Key: (since: CFTimeInterval, reported: Bool)] = [:]

    /// `since` is when the condition started, or nil when it isn't present
    /// now. A condition is reported once, when it has lasted `threshold`;
    /// its end is reported only if its start was. A different `since` is a
    /// new occurrence — the old one ended in between.
    mutating func update(
        _ key: Key, since: CFTimeInterval?, now: CFTimeInterval, threshold: CFTimeInterval
    ) -> Transition {
        let previous = ongoing[key]
        guard let since else {
            ongoing[key] = nil
            return previous?.reported == true ? .ended(lasted: now - previous!.since) : .none
        }
        if let previous, previous.since != since {
            ongoing[key] = (since, false)
            if previous.reported { return .ended(lasted: now - previous.since) }
        } else if previous == nil {
            ongoing[key] = (since, false)
        }
        guard ongoing[key]?.reported == false, now - since >= threshold else { return .none }
        ongoing[key]?.reported = true
        return .began(elapsed: now - since)
    }
}
