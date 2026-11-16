/// A plain-value copy of a `LayoutTree`, so the layout can be saved and survive a restart.
public indirect enum LayoutSnapshot: Sendable, Equatable, Codable {
    case split(axis: Axis, ratio: Double, first: LayoutSnapshot, second: LayoutSnapshot)
    case group(windows: [WindowID], activeIndex: Int)
}

extension LayoutTree {
    public var snapshot: LayoutSnapshot? { root.map(Self.snapshot(of:)) }

    /// Replaces the tree with `snapshot`, keeping only the windows `keep` accepts.
    /// Tiles of dropped windows disappear as if the windows had been removed.
    public func restore(_ snapshot: LayoutSnapshot, keeping keep: (WindowID) -> Bool = { _ in true }) {
        root = Self.node(from: snapshot)
        root?.parent = nil
        for id in windows where !keep(id) { remove(id) }
    }

    private static func snapshot(of node: Node) -> LayoutSnapshot {
        switch node {
        case let s as SplitNode:
            return .split(axis: s.axis, ratio: s.ratio, first: snapshot(of: s.first), second: snapshot(of: s.second))
        case let g as GroupNode:
            return .group(windows: g.windows, activeIndex: g.activeIndex)
        default:
            fatalError("unknown node type")
        }
    }

    /// Nil for an empty group; a split with an empty side collapses into the other side.
    private static func node(from snapshot: LayoutSnapshot) -> Node? {
        switch snapshot {
        case let .split(axis, ratio, first, second):
            switch (node(from: first), node(from: second)) {
            case let (a?, b?): return SplitNode(axis: axis, ratio: min(max(ratio, 0.05), 0.95), first: a, second: b)
            case let (a?, nil): return a
            case let (nil, b): return b
            }
        case let .group(windows, activeIndex):
            guard !windows.isEmpty else { return nil }
            return GroupNode(windows, activeIndex: min(max(activeIndex, 0), windows.count - 1))
        }
    }
}
