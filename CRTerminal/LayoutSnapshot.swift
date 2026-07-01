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
    /// Whether the session rail was collapsed to its icon-only width.
    var sidebarCollapsed: Bool = false
}

extension WindowNode {
    private enum CodingKeys: String, CodingKey {
        case frame, activeTabIndex, tabs, sidebarCollapsed
    }

    /// Hand-rolled decode so a snapshot written before `sidebarCollapsed`
    /// existed defaults to `false` rather than failing — the synthesized
    /// decoder requires every non-optional key, so it wouldn't tolerate the
    /// missing one (unlike `TabNode.customName`, which is Optional). Keeping
    /// the memberwise init means this lives in an extension; `encode` stays
    /// synthesized off `CodingKeys`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(CGRect.self, forKey: .frame)
        activeTabIndex = try c.decode(Int.self, forKey: .activeTabIndex)
        tabs = try c.decode([TabNode].self, forKey: .tabs)
        sidebarCollapsed = try c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? false
    }
}

/// One sidebar session: stable id, its theme, and the root of its pane tree.
/// A tab's container holds exactly one root view (a lone pane or a split),
/// so the tree has a single `root` rather than a list.
struct TabNode: Codable, Equatable {
    var uuid: UUID
    var presetName: String
    var root: SplitNode
    /// User-chosen session name; `nil` when the row uses its automatic name.
    /// Optional + defaulted so older snapshots (without the key) decode cleanly.
    var customName: String? = nil
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
