import CoreGraphics
import Foundation

/// The lightweight window/tab/split *layout* tree (session restoration R2).
/// It carries only structure and identity — frames, tab order, the split
/// nesting, preset names, and the per-pane session UUIDs that key the heavy
/// terminal contents in `SessionStateStore`. ARCHITECTURE.md's two-tier
/// persistence: this rides `NSWindowRestoration` (R3); the grids/scrollback
/// never do.
struct LayoutSnapshot: Codable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var windows: [WindowNode]
}

/// One window: its frame, which tab was active, and its tabs in order.
struct WindowNode: Codable, Equatable {
    var frame: CGRect
    var activeTabIndex: Int
    var tabs: [TabNode]
}

/// One sidebar session: stable id, its theme, and the root of its pane tree.
/// A tab's container holds exactly one root view (a lone pane or a split),
/// so the tree has a single `root` rather than a list.
struct TabNode: Codable, Equatable {
    var uuid: UUID
    var presetName: String
    var root: SplitNode
}

/// The pane tree inside a tab: leaves are panes (keyed by session UUID),
/// internal nodes are `NSSplitView`s. `dividerFractions` are the cumulative
/// divider positions as a fraction of the split's length (count = children
/// − 1), applied after layout on rebuild.
indirect enum SplitNode: Codable, Equatable {
    case leaf(sessionID: UUID)
    case split(isVertical: Bool, dividerFractions: [Double], children: [SplitNode])

    /// Every session UUID referenced by this subtree (for content save/prune).
    var sessionIDs: [UUID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, let children):
            return children.flatMap(\.sessionIDs)
        }
    }
}
