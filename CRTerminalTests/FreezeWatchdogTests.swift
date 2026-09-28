import Foundation
import Testing
import os
@testable import CRTerminal

struct IncidentTrackerTests {
    @Test func reportsOnceTheConditionHasLastedItsThreshold() {
        var tracker = IncidentTracker<String>()
        #expect(tracker.update("stall", since: 10, now: 10, threshold: 2) == .none)
        #expect(tracker.update("stall", since: 10, now: 11, threshold: 2) == .none)
        #expect(tracker.update("stall", since: 10, now: 12.5, threshold: 2)
            == .began(elapsed: 2.5))
        // Reported once, not on every tick it persists.
        #expect(tracker.update("stall", since: 10, now: 13.5, threshold: 2) == .none)
        #expect(tracker.update("stall", since: nil, now: 14, threshold: 2)
            == .ended(lasted: 4))
    }

    @Test func aShortConditionClearsSilently() {
        var tracker = IncidentTracker<String>()
        #expect(tracker.update("stall", since: 10, now: 11, threshold: 2) == .none)
        #expect(tracker.update("stall", since: nil, now: 12, threshold: 2) == .none)
    }

    @Test func aNewStartTimeIsANewOccurrence() {
        // Two back-to-back draws each caught mid-flight are not one long
        // draw: the start time moved, so the clock restarts.
        var tracker = IncidentTracker<String>()
        #expect(tracker.update("draw", since: 10, now: 11, threshold: 2) == .none)
        #expect(tracker.update("draw", since: 11.5, now: 12, threshold: 2) == .none)
        #expect(tracker.update("draw", since: 11.5, now: 14, threshold: 2)
            == .began(elapsed: 2.5))
        // A reported occurrence replaced by a fresh one reports its end.
        #expect(tracker.update("draw", since: 15, now: 15.5, threshold: 2)
            == .ended(lasted: 4))
        #expect(tracker.update("draw", since: 15, now: 17, threshold: 2)
            == .began(elapsed: 2))
    }

    @Test func keysAreTrackedIndependently() {
        var tracker = IncidentTracker<Int>()
        #expect(tracker.update(1, since: 0, now: 3, threshold: 2) == .began(elapsed: 3))
        #expect(tracker.update(2, since: 0, now: 3, threshold: 2) == .began(elapsed: 3))
        #expect(tracker.update(1, since: nil, now: 4, threshold: 2) == .ended(lasted: 4))
        #expect(tracker.update(2, since: 0, now: 4, threshold: 2) == .none)
    }
}

struct UndrawnOutputTests {
    private func health(
        occluded: Bool = false, windowVisible: Bool = true,
        lastDrawAt: CFTimeInterval? = 100, lastDrawnGeneration: UInt64? = 7
    ) -> RenderLoop.Health {
        RenderLoop.Health(
            occluded: occluded, invalidated: false, windowVisible: windowVisible,
            linkPaused: true, drawCount: 1, createdAt: 50, lastDrawAt: lastDrawAt,
            lastDrawnGeneration: lastDrawnGeneration, drawStartedAt: nil, renderThread: 0)
    }

    @Test func pendingOutputWithNoRecentFrameIsUndrawn() {
        #expect(FreezeWatchdog.hasUndrawnOutput(health(), displayGeneration: 8, now: 105))
    }

    @Test func drawnOutputIsNot() {
        #expect(!FreezeWatchdog.hasUndrawnOutput(health(), displayGeneration: 7, now: 105))
    }

    @Test func aRecentFrameMeansTheLinkIsStillCatchingUp() {
        #expect(!FreezeWatchdog.hasUndrawnOutput(health(), displayGeneration: 8, now: 100.5))
    }

    @Test func hiddenPanesAndWindowsAreExpectedNotToDraw() {
        #expect(!FreezeWatchdog.hasUndrawnOutput(
            health(occluded: true), displayGeneration: 8, now: 105))
        #expect(!FreezeWatchdog.hasUndrawnOutput(
            health(windowVisible: false), displayGeneration: 8, now: 105))
    }

    @Test func aBusyTerminalLockSkipsTheCheck() {
        #expect(!FreezeWatchdog.hasUndrawnOutput(health(), displayGeneration: nil, now: 105))
    }

    @Test func aPaneThatNeverDrewCountsFromItsCreation() {
        let fresh = health(lastDrawAt: nil, lastDrawnGeneration: nil)
        #expect(!FreezeWatchdog.hasUndrawnOutput(fresh, displayGeneration: 0, now: 50.5))
        #expect(FreezeWatchdog.hasUndrawnOutput(fresh, displayGeneration: 0, now: 52))
    }
}

struct ThreadBacktraceTests {
    @Test func samplesABlockedThreadAndLetsItCarryOn() {
        let parked = OSAllocatedUnfairLock<thread_t>(initialState: 0)
        let gate = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            parked.withLock { $0 = pthread_mach_thread_np(pthread_self()) }
            gate.wait()
            finished.signal()
        }
        thread.start()
        while parked.withLock({ $0 }) == 0 { usleep(1_000) }
        usleep(50_000) // let it reach the semaphore wait

        let frames = ThreadBacktrace.capture(parked.withLock { $0 })
        gate.signal()
        // Suspended and resumed: the thread still runs to completion.
        #expect(finished.wait(timeout: .now() + 5) == .success)

        #expect(frames.count >= 4)
        let lines = ThreadBacktrace.symbolicate(frames)
        // Parked in the kernel's semaphore trap.
        #expect(lines.first?.contains("libsystem_kernel.dylib") == true)
    }

    @Test func refusesToSampleItsOwnThread() {
        #expect(ThreadBacktrace.capture(pthread_mach_thread_np(pthread_self())).isEmpty)
        #expect(ThreadBacktrace.capture(0).isEmpty)
    }

    @Test func demanglesSwiftSymbolsAndPassesCSymbolsThrough() {
        #expect(ThreadBacktrace.demangle("$s10CRTerminal10RenderLoopC4pokeyySb_tF")
            == "CRTerminal.RenderLoop.poke(Swift.Bool) -> ()")
        #expect(ThreadBacktrace.demangle("semaphore_wait_trap") == "semaphore_wait_trap")
    }

    @Test func findsTheExecutableUUID() {
        #expect(ThreadBacktrace.executableUUID.flatMap(UUID.init(uuidString:)) != nil)
    }
}

@MainActor
struct InFlightRequestsTests {
    @Test func laterCallersShareTheFirstCallersJob() {
        let requests = InFlightRequests<String, Int>()
        var results: [String] = []
        #expect(requests.join("repo", { results.append("first \($0)") }))
        #expect(!requests.join("repo", { results.append("second \($0)") }))
        #expect(requests.join("other", { results.append("other \($0)") }))
        requests.finish("repo", with: 3)
        #expect(results == ["first 3", "second 3"])
        // Finished: the next request starts a fresh job.
        #expect(requests.join("repo", { _ in }))
    }
}

struct DiagnosticReportTests {
    @Test func reportCarriesTheHeaderAndExtraSections() {
        let report = FreezeWatchdog.shared.report(extraSections: ["Windows (0):"])
        #expect(report.contains("diagnostic report"))
        #expect(report.contains("Main thread: slowest ping"))
        #expect(report.contains("Windows (0):"))
        #expect(report.contains("Panes ("))
        #expect(report.contains("Events ("))
    }

    @Test func testRunsWriteReportsToAScratchDirectory() {
        #expect(!FreezeWatchdog.reportsDirectory.path.contains("/Library/Logs/"))
    }
}
