import CoreGraphics
import Foundation
import Testing
@testable import CRTerminal

/// A representative gutter: 14pt wide, 400pt tall, top edge at y=10 (flipped
/// coordinates, so larger y is further down the screen).
private let lane = CGRect(x: 586, y: 10, width: 14, height: 400)

struct ScrollbarGeometryTests {
    @Test func knobProportionalToVisibleFraction() {
        // 20 visible rows over 80 scrollback lines → knob ≈ 20/100 of the lane.
        let geo = ScrollbarGeometry.compute(
            lane: lane, scrollOffset: 0, maxOffset: 80, rows: 20, knobWidth: 7)
        #expect(abs(geo.knob.height - lane.height * 0.2) < 1)
    }

    @Test func knobClampsToMinimumLength() {
        // 24 rows over a huge scrollback would be a sliver; it clamps.
        let geo = ScrollbarGeometry.compute(
            lane: lane, scrollOffset: 0, maxOffset: 100_000, rows: 24, knobWidth: 7)
        #expect(geo.knob.height == ScrollbarGeometry.minKnobLength)
    }

    @Test func liveSitsAtBottomOldestAtTop() {
        let live = ScrollbarGeometry.compute(
            lane: lane, scrollOffset: 0, maxOffset: 80, rows: 20, knobWidth: 7)
        // scrollOffset 0 → knob flush with the lane's bottom edge.
        #expect(abs(live.knob.maxY - lane.maxY) < 0.5)

        let oldest = ScrollbarGeometry.compute(
            lane: lane, scrollOffset: 80, maxOffset: 80, rows: 20, knobWidth: 7)
        // Fully scrolled back → knob flush with the lane's top edge.
        #expect(abs(oldest.knob.minY - lane.minY) < 0.5)
    }

    @Test func offsetRoundTripsThroughKnobTop() {
        let geo = ScrollbarGeometry.compute(
            lane: lane, scrollOffset: 30, maxOffset: 80, rows: 20, knobWidth: 7)
        // The knob's own top maps back to the offset it was built from.
        #expect(geo.offset(forKnobTop: geo.knob.minY) == 30)
    }

    @Test func offsetClampsBeyondTheLane() {
        let geo = ScrollbarGeometry.compute(
            lane: lane, scrollOffset: 0, maxOffset: 80, rows: 20, knobWidth: 7)
        #expect(geo.offset(forKnobTop: lane.minY - 999) == 80) // past the top
        #expect(geo.offset(forKnobTop: lane.maxY + 999) == 0)  // past the bottom
    }

    @Test func knobSitsInTheLaneAndKnobHitsRegisterAsLaneHits() {
        let geo = ScrollbarGeometry.compute(
            lane: lane, scrollOffset: 40, maxOffset: 80, rows: 20, knobWidth: 7)
        let center = CGPoint(x: geo.knob.midX, y: geo.knob.midY)
        #expect(geo.hitsKnob(center))
        #expect(geo.hitsLane(center))
        // A point in the lane but above the knob is a lane hit, not a knob hit.
        let aboveKnob = CGPoint(x: geo.knob.midX, y: lane.minY + 1)
        #expect(geo.hitsLane(aboveKnob))
        #expect(!geo.hitsKnob(aboveKnob))
    }
}
