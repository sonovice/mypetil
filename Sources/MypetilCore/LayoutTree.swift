import CoreGraphics

// MARK: - Nodes

/// A node of the binary layout tree: either a split or a tab group (leaf).
class Node {
    weak var parent: SplitNode?

    func copy() -> Node { fatalError("abstract") }
}

/// Splits its rectangle between two children along `axis`.
final class SplitNode: Node {
    var axis: Axis
    /// Share of the available length the first child wants (0...1).
    /// The effective share may differ when minimum sizes force it.
    var ratio: Double
    var first: Node { didSet { first.parent = self } }
    var second: Node { didSet { second.parent = self } }

    init(axis: Axis, ratio: Double = 0.5, first: Node, second: Node) {
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
        super.init()
        first.parent = self
        second.parent = self
    }

    func replace(_ child: Node, with new: Node) {
        if child === first { first = new } else if child === second { second = new }
    }

    func sibling(of child: Node) -> Node { child === first ? second : first }

    override func copy() -> Node {
        SplitNode(axis: axis, ratio: ratio, first: first.copy(), second: second.copy())
    }
}

/// A leaf: one or more windows sharing the same rectangle, shown as tabs.
final class GroupNode: Node {
    var windows: [WindowID]
    var activeIndex: Int

    init(_ windows: [WindowID], activeIndex: Int = 0) {
        self.windows = windows
        self.activeIndex = activeIndex
    }

    var activeWindow: WindowID { windows[activeIndex] }

    override func copy() -> Node { GroupNode(windows, activeIndex: activeIndex) }
}

// MARK: - Layout output

public struct LayoutOptions: Sendable, Equatable {
    /// Space between tiles.
    public var gap: CGFloat
    /// Height of the tab strip shown above a group.
    public var tabBarHeight: CGFloat
    /// Show a tab strip even for groups that hold a single window.
    public var showTabBarForSingleWindow: Bool

    public init(gap: CGFloat = 8, tabBarHeight: CGFloat = 26, showTabBarForSingleWindow: Bool = false) {
        self.gap = gap
        self.tabBarHeight = tabBarHeight
        self.showTabBarForSingleWindow = showTabBarForSingleWindow
    }
}

/// Where one tab group ended up.
public struct GroupLayout: Sendable, Equatable {
    public let windows: [WindowID]
    public let activeIndex: Int
    /// The whole tile, including the tab strip.
    public let frame: CGRect
    /// The tab strip, if one is shown.
    public let tabBarFrame: CGRect?
    /// Where the active window goes.
    public let windowFrame: CGRect

    public var activeWindow: WindowID { windows[activeIndex] }
}

public struct LayoutResult: Sendable, Equatable {
    /// Groups in tree order (left-to-right, top-to-bottom).
    public let groups: [GroupLayout]
    /// True if the minimum sizes did not fit into the bounds and tiles overflow.
    public let overflows: Bool

    public static let empty = LayoutResult(groups: [], overflows: false)

    public func group(containing window: WindowID) -> GroupLayout? {
        groups.first { $0.windows.contains(window) }
    }

    /// The group whose tile contains `point`.
    public func group(at point: CGPoint) -> GroupLayout? {
        groups.first { $0.frame.contains(point) }
    }
}

// MARK: - Tree

/// The tiling layout of one display: a binary tree of splits whose leaves are tab groups.
///
/// The tree stores intent (split axes, ratios, tab order). Concrete rectangles are
/// produced by `layout(in:minSizes:options:)`, which honours per-window minimum sizes.
public final class LayoutTree {
    var root: Node?

    public init() {}

    public var isEmpty: Bool { root == nil }

    /// A deep copy, used to simulate drops for the drag preview.
    public func copy() -> LayoutTree {
        let t = LayoutTree()
        t.root = root?.copy()
        return t
    }

    // MARK: Queries

    var groupNodes: [GroupNode] {
        var out: [GroupNode] = []
        func walk(_ n: Node?) {
            switch n {
            case let g as GroupNode: out.append(g)
            case let s as SplitNode: walk(s.first); walk(s.second)
            default: break
            }
        }
        walk(root)
        return out
    }

    func groupNode(containing window: WindowID) -> GroupNode? {
        groupNodes.first { $0.windows.contains(window) }
    }

    public func contains(_ window: WindowID) -> Bool { groupNode(containing: window) != nil }

    /// All windows in tree order; tabs of one group are adjacent.
    public var windows: [WindowID] { groupNodes.flatMap(\.windows) }

    /// Windows sharing a tab group with `window` (including itself).
    public func tabs(of window: WindowID) -> [WindowID] { groupNode(containing: window)?.windows ?? [] }

    public func isActiveTab(_ window: WindowID) -> Bool { groupNode(containing: window)?.activeWindow == window }

    // MARK: Mutations

    /// Adds a new window by halving the tile of `target` along its longer side.
    /// Without a target (or if it is not in the tree) the largest tile is split.
    public func insert(_ window: WindowID, near target: WindowID?, bounds: CGRect,
                       minSizes: [WindowID: CGSize] = [:], options: LayoutOptions = .init()) {
        remove(window)
        guard root != nil else {
            root = GroupNode([window])
            return
        }
        let frames = computeFrames(in: bounds, minSizes: minSizes, options: options)
        let targetGroup = target.flatMap(groupNode(containing:))
            ?? groupNodes.max { area(frames[ObjectIdentifier($0)]) < area(frames[ObjectIdentifier($1)]) }!
        let frame = frames[ObjectIdentifier(targetGroup)] ?? bounds
        let axis: Axis = frame.width >= frame.height ? .horizontal : .vertical
        split(targetGroup, with: GroupNode([window]), axis: axis, newFirst: false)
    }

    /// Removes a window. Empty groups disappear and their sibling takes over the space.
    public func remove(_ window: WindowID) {
        guard let g = groupNode(containing: window), let idx = g.windows.firstIndex(of: window) else { return }
        g.windows.remove(at: idx)
        if g.windows.isEmpty {
            removeNode(g)
            return
        }
        if idx < g.activeIndex || g.activeIndex >= g.windows.count {
            g.activeIndex = max(0, g.activeIndex - 1)
        }
    }

    /// Moves `window` (which may or may not be in this tree yet) next to `target`.
    ///
    /// Edge zones halve the target's tile; `.center` adds the window as a tab.
    /// Returns false if the drop would change nothing.
    @discardableResult
    public func drop(_ window: WindowID, onto target: WindowID, zone: Zone) -> Bool {
        guard let targetGroup = groupNode(containing: target) else { return false }
        let sourceGroup = groupNode(containing: window)

        if sourceGroup === targetGroup {
            if zone == .center || targetGroup.windows.count == 1 {
                // Dropped onto its own tile: at most make it the active tab.
                return activate(window)
            }
        }

        remove(window)
        if let axis = zone.axis {
            split(targetGroup, with: GroupNode([window]), axis: axis, newFirst: zone.insertsFirst)
        } else {
            targetGroup.windows.append(window)
            targetGroup.activeIndex = targetGroup.windows.count - 1
        }
        return true
    }

    /// Puts `window` into an empty tree (or splits the largest tile of a non-empty one).
    public func dropIntoEmptySpace(_ window: WindowID, bounds: CGRect) {
        insert(window, near: nil, bounds: bounds)
    }

    /// Makes `window` the visible tab of its group. Returns true if anything changed.
    @discardableResult
    public func activate(_ window: WindowID) -> Bool {
        guard let g = groupNode(containing: window), let idx = g.windows.firstIndex(of: window),
              idx != g.activeIndex else { return false }
        g.activeIndex = idx
        return true
    }

    /// Activates the tab `offset` positions away (wrapping) and returns it.
    @discardableResult
    public func cycleTab(of window: WindowID, by offset: Int) -> WindowID? {
        guard let g = groupNode(containing: window), g.windows.count > 1 else { return nil }
        let n = g.windows.count
        g.activeIndex = ((g.activeIndex + offset) % n + n) % n
        return g.activeWindow
    }

    /// Exchanges the tiles of two windows (whole tab groups move together).
    public func swap(_ a: WindowID, _ b: WindowID) {
        guard let ga = groupNode(containing: a), let gb = groupNode(containing: b), ga !== gb else { return }
        (ga.windows, gb.windows) = (gb.windows, ga.windows)
        (ga.activeIndex, gb.activeIndex) = (gb.activeIndex, ga.activeIndex)
    }

    /// Flips the axis of the split directly containing `window`'s tile.
    public func toggleSplitAxis(of window: WindowID) {
        guard let parent = groupNode(containing: window)?.parent else { return }
        parent.axis = parent.axis.flipped
    }

    /// Resets every split to 50/50.
    public func balance() {
        func walk(_ n: Node?) {
            guard let s = n as? SplitNode else { return }
            s.ratio = 0.5
            walk(s.first); walk(s.second)
        }
        walk(root)
    }

    /// Adapts split ratios after the user resized a tiled window by hand.
    ///
    /// Every edge of the window that moved drags the nearest split boundary on that side along.
    public func applyManualResize(of window: WindowID, from old: CGRect, to new: CGRect, bounds: CGRect,
                                  minSizes: [WindowID: CGSize] = [:], options: LayoutOptions = .init()) {
        guard let g = groupNode(containing: window) else { return }
        let frames = computeFrames(in: bounds, minSizes: minSizes, options: options)
        let tolerance: CGFloat = 1
        let moves: [(delta: CGFloat, axis: Axis, isSecond: Bool)] = [
            (new.minX - old.minX, .horizontal, true),   // left edge: boundary before us
            (new.maxX - old.maxX, .horizontal, false),  // right edge: boundary after us
            (new.minY - old.minY, .vertical, true),     // top edge
            (new.maxY - old.maxY, .vertical, false),    // bottom edge
        ]
        for move in moves where abs(move.delta) > tolerance {
            guard let split = ancestorSplit(of: g, axis: move.axis, onSecondSide: move.isSecond),
                  let rect = frames[ObjectIdentifier(split)],
                  let firstRect = frames[ObjectIdentifier(split.first)] else { continue }
            let length = (move.axis == .horizontal ? rect.width : rect.height) - options.gap
            guard length > 0 else { continue }
            // Start from the effective size (minimum sizes may override the stored ratio).
            let firstLength = move.axis == .horizontal ? firstRect.width : firstRect.height
            let newFirstLength = firstLength + move.delta
            split.ratio = Double(min(0.95, max(0.05, newFirstLength / length)))
        }
    }

    // MARK: Navigation

    /// The active window of the tile adjacent to `window`'s tile in `direction`.
    public func neighbor(of window: WindowID, _ direction: Direction, in layout: LayoutResult) -> WindowID? {
        guard let src = layout.group(containing: window)?.frame else { return nil }
        let slack: CGFloat = 2
        var best: (WindowID, CGFloat, CGFloat)?
        for g in layout.groups where !g.windows.contains(window) {
            let f = g.frame
            let distance: CGFloat
            let overlap: CGFloat
            switch direction {
            case .left:
                guard f.maxX <= src.minX + slack else { continue }
                distance = src.minX - f.maxX
                overlap = min(f.maxY, src.maxY) - max(f.minY, src.minY)
            case .right:
                guard f.minX >= src.maxX - slack else { continue }
                distance = f.minX - src.maxX
                overlap = min(f.maxY, src.maxY) - max(f.minY, src.minY)
            case .up:
                guard f.maxY <= src.minY + slack else { continue }
                distance = src.minY - f.maxY
                overlap = min(f.maxX, src.maxX) - max(f.minX, src.minX)
            case .down:
                guard f.minY >= src.maxY - slack else { continue }
                distance = f.minY - src.maxY
                overlap = min(f.maxX, src.maxX) - max(f.minX, src.minX)
            }
            guard overlap > 0 else { continue }
            if best == nil || distance < best!.1 || (distance == best!.1 && overlap > best!.2) {
                best = (g.activeWindow, distance, overlap)
            }
        }
        return best?.0
    }

    // MARK: Layout

    /// Computes the rectangles of all tab groups inside `bounds`.
    ///
    /// Split ratios are honoured as long as every window gets at least its minimum size.
    /// When the minimums do not fit at all, space is shared in proportion to them and
    /// `overflows` is set.
    public func layout(in bounds: CGRect, minSizes: [WindowID: CGSize] = [:],
                       options: LayoutOptions = .init()) -> LayoutResult {
        var overflows = false
        let frames = computeFrames(in: bounds, minSizes: minSizes, options: options, overflows: &overflows)
        let groups = groupNodes.map { g -> GroupLayout in
            let frame = frames[ObjectIdentifier(g)] ?? .zero
            if showsTabBar(g, options) {
                let bar = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: options.tabBarHeight)
                let win = CGRect(x: frame.minX, y: frame.minY + options.tabBarHeight,
                                 width: frame.width, height: max(0, frame.height - options.tabBarHeight))
                return GroupLayout(windows: g.windows, activeIndex: g.activeIndex, frame: frame,
                                   tabBarFrame: bar, windowFrame: win)
            }
            return GroupLayout(windows: g.windows, activeIndex: g.activeIndex, frame: frame,
                               tabBarFrame: nil, windowFrame: frame)
        }
        return LayoutResult(groups: groups, overflows: overflows)
    }

    // MARK: Internals

    private func split(_ existing: Node, with new: Node, axis: Axis, newFirst: Bool) {
        let parent = existing.parent
        let s = SplitNode(axis: axis, first: newFirst ? new : existing, second: newFirst ? existing : new)
        if let parent {
            parent.replace(existing, with: s)
        } else {
            root = s
            s.parent = nil
        }
    }

    private func removeNode(_ node: Node) {
        guard let parent = node.parent else {
            root = nil
            return
        }
        let sibling = parent.sibling(of: node)
        if let grand = parent.parent {
            grand.replace(parent, with: sibling)
        } else {
            root = sibling
            sibling.parent = nil
        }
    }

    /// Nearest ancestor split along `axis` where `node` lies in the second (or first) child.
    private func ancestorSplit(of node: Node, axis: Axis, onSecondSide: Bool) -> SplitNode? {
        var child: Node = node
        while let p = child.parent {
            if p.axis == axis, (p.second === child) == onSecondSide { return p }
            child = p
        }
        return nil
    }

    private func showsTabBar(_ g: GroupNode, _ options: LayoutOptions) -> Bool {
        g.windows.count > 1 || options.showTabBarForSingleWindow
    }

    private func minSize(of node: Node, _ minSizes: [WindowID: CGSize], _ options: LayoutOptions) -> CGSize {
        switch node {
        case let g as GroupNode:
            var size = g.windows.reduce(CGSize.zero) { acc, w in
                let m = minSizes[w] ?? .zero
                return CGSize(width: max(acc.width, m.width), height: max(acc.height, m.height))
            }
            if showsTabBar(g, options) { size.height += options.tabBarHeight }
            return size
        case let s as SplitNode:
            let a = minSize(of: s.first, minSizes, options)
            let b = minSize(of: s.second, minSizes, options)
            switch s.axis {
            case .horizontal: return CGSize(width: a.width + options.gap + b.width, height: max(a.height, b.height))
            case .vertical: return CGSize(width: max(a.width, b.width), height: a.height + options.gap + b.height)
            }
        default:
            return .zero
        }
    }

    func computeFrames(in bounds: CGRect, minSizes: [WindowID: CGSize],
                       options: LayoutOptions) -> [ObjectIdentifier: CGRect] {
        var ignored = false
        return computeFrames(in: bounds, minSizes: minSizes, options: options, overflows: &ignored)
    }

    private func computeFrames(in bounds: CGRect, minSizes: [WindowID: CGSize], options: LayoutOptions,
                               overflows: inout Bool) -> [ObjectIdentifier: CGRect] {
        var frames: [ObjectIdentifier: CGRect] = [:]
        var overflow = false
        func place(_ node: Node, _ rect: CGRect) {
            frames[ObjectIdentifier(node)] = rect.pixelAligned
            guard let s = node as? SplitNode else { return }
            let minA = minSize(of: s.first, minSizes, options)
            let minB = minSize(of: s.second, minSizes, options)
            let total = s.axis == .horizontal ? rect.width : rect.height
            let available = max(0, total - options.gap)
            let needA = s.axis == .horizontal ? minA.width : minA.height
            let needB = s.axis == .horizontal ? minB.width : minB.height

            let lengthA: CGFloat
            if needA + needB <= available {
                lengthA = min(max(available * CGFloat(s.ratio), needA), available - needB)
            } else {
                // Does not fit: share the shortfall in proportion to what each side needs.
                overflow = true
                lengthA = needA + needB > 0 ? available * needA / (needA + needB) : available / 2
            }
            let lengthB = available - lengthA
            switch s.axis {
            case .horizontal:
                place(s.first, CGRect(x: rect.minX, y: rect.minY, width: lengthA, height: rect.height))
                place(s.second, CGRect(x: rect.minX + lengthA + options.gap, y: rect.minY,
                                       width: lengthB, height: rect.height))
            case .vertical:
                place(s.first, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: lengthA))
                place(s.second, CGRect(x: rect.minX, y: rect.minY + lengthA + options.gap,
                                       width: rect.width, height: lengthB))
            }
        }
        if let root { place(root, bounds) }
        // A single tile can still be too small for its window.
        let rootMin = root.map { minSize(of: $0, minSizes, options) } ?? .zero
        if rootMin.width > bounds.width + 0.5 || rootMin.height > bounds.height + 0.5 { overflow = true }
        overflows = overflow
        return frames
    }

    private func area(_ r: CGRect?) -> CGFloat { r.map { $0.width * $0.height } ?? 0 }
}
