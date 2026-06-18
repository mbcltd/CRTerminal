import CoreGraphics
import Foundation
import Testing
@testable import CRTerminal

/// Session restoration R2: the layout tree encodes/decodes losslessly and
/// the split-node helpers behave.
struct LayoutSnapshotTests {
    private func sample() -> LayoutSnapshot {
        // A window with three tabs; the middle one is a 2×2 split.
        let quad = SplitNode.split(
            isVertical: true, dividerFractions: [0.5],
            children: [
                .split(isVertical: false, dividerFractions: [0.5],
                       children: [.leaf(sessionID: UUID()), .leaf(sessionID: UUID())]),
                .split(isVertical: false, dividerFractions: [0.4],
                       children: [.leaf(sessionID: UUID()), .leaf(sessionID: UUID())]),
            ])
        let tabs = [
            TabNode(uuid: UUID(), presetName: "Dark", root: .leaf(sessionID: UUID()),
                    customName: "build server"),
            TabNode(uuid: UUID(), presetName: "IBM 5151", root: quad),
            TabNode(uuid: UUID(), presetName: "Light", root: .leaf(sessionID: UUID())),
        ]
        let window = WindowNode(
            frame: CGRect(x: 40, y: 60, width: 1000, height: 700),
            activeTabIndex: 1, tabs: tabs)
        return LayoutSnapshot(windows: [window])
    }

    @Test func roundTripsThroughBinaryPlist() throws {
        let layout = sample()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(layout)
        let decoded = try PropertyListDecoder().decode(LayoutSnapshot.self, from: data)
        #expect(decoded == layout)
    }

    @Test func carriesVersion() {
        #expect(sample().version == LayoutSnapshot.currentVersion)
    }

    @Test func sessionIDsFlattensTheTree() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree = SplitNode.split(
            isVertical: false, dividerFractions: [0.3, 0.6],
            children: [.leaf(sessionID: a), .leaf(sessionID: b), .leaf(sessionID: c)])
        #expect(tree.sessionIDs == [a, b, c])
    }

    @Test func leafSessionIDsIsSingleton() {
        let id = UUID()
        #expect(SplitNode.leaf(sessionID: id).sessionIDs == [id])
    }

    @Test func quadSplitHasFourLeaves() {
        let layout = sample()
        let middle = layout.windows[0].tabs[1].root
        #expect(middle.sessionIDs.count == 4)
    }

    @Test func customNameSurvivesEncoding() throws {
        let layout = sample()
        let data = try PropertyListEncoder().encode(layout)
        let decoded = try PropertyListDecoder().decode(LayoutSnapshot.self, from: data)
        #expect(decoded.windows[0].tabs[0].customName == "build server")
        #expect(decoded.windows[0].tabs[1].customName == nil)
    }

    /// Backward compatibility: a TabNode written before `customName` existed
    /// (no such key) decodes to `nil` rather than failing — so older restore
    /// files still load. This is why no schema version bump is needed.
    @Test func legacyTabNodeWithoutCustomNameDecodes() throws {
        struct LegacyTabNode: Codable {
            var uuid: UUID
            var presetName: String
            var root: SplitNode
        }
        let legacy = LegacyTabNode(
            uuid: UUID(), presetName: "Dark", root: .leaf(sessionID: UUID()))
        let data = try PropertyListEncoder().encode(legacy)
        let decoded = try PropertyListDecoder().decode(TabNode.self, from: data)
        #expect(decoded.customName == nil)
        #expect(decoded.presetName == "Dark")
    }

    @Test func frameSurvivesEncoding() throws {
        let layout = sample()
        let data = try PropertyListEncoder().encode(layout)
        let decoded = try PropertyListDecoder().decode(LayoutSnapshot.self, from: data)
        #expect(decoded.windows[0].frame == CGRect(x: 40, y: 60, width: 1000, height: 700))
        #expect(decoded.windows[0].activeTabIndex == 1)
    }
}
