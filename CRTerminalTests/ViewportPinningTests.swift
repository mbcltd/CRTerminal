import Testing
@testable import CRTerminal

/// Covers `TerminalView.pinnedScrollOffset`: the rule that keeps the viewport
/// anchored to the same content as output scrolls past while the user is
/// scrolled up, and lets it follow the live tail otherwise.
struct ViewportPinningTests {
    @Test func atLiveStaysFollowingTheTail() {
        // Offset 0 (live) never moves, no matter how much output arrives.
        #expect(TerminalView.pinnedScrollOffset(
            current: 0, screenTopGrowth: 42, resized: false,
            scrollbackCount: 1000) == 0)
    }

    @Test func scrolledUpAnchorsToContent() {
        // Scrolled up 30 lines; 5 lines scrolled into scrollback this frame.
        // The offset grows by 5 so the same absolute rows stay on screen.
        #expect(TerminalView.pinnedScrollOffset(
            current: 30, screenTopGrowth: 5, resized: false,
            scrollbackCount: 1000) == 35)
    }

    @Test func anchoredRowIsInvariantAcrossAppends() {
        // Drive a sequence of appends and assert the anchored absolute row
        // (absoluteScreenTop - offset) is held constant.
        var screenTop = 200          // absoluteScreenTop
        var offset = 40
        let anchor = screenTop - offset
        for grew in [1, 1, 3, 10, 2] {
            screenTop += grew
            offset = TerminalView.pinnedScrollOffset(
                current: offset, screenTopGrowth: grew, resized: false,
                scrollbackCount: screenTop) // scrollback grows with the top
            #expect(screenTop - offset == anchor)
        }
    }

    @Test func resizeSkipsTheBump() {
        // Across a reflow the growth is ignored so the view doesn't lurch.
        #expect(TerminalView.pinnedScrollOffset(
            current: 30, screenTopGrowth: 5, resized: true,
            scrollbackCount: 1000) == 30)
    }

    @Test func anchorBeyondScrollbackDriftsTowardLive() {
        // Once the anchored row falls off the top of scrollback, the clamp
        // caps the offset — the view starts drifting, matching other terminals.
        #expect(TerminalView.pinnedScrollOffset(
            current: 95, screenTopGrowth: 10, resized: false,
            scrollbackCount: 100) == 100)
    }

    @Test func noGrowthLeavesOffsetUntouched() {
        #expect(TerminalView.pinnedScrollOffset(
            current: 30, screenTopGrowth: 0, resized: false,
            scrollbackCount: 1000) == 30)
    }
}
