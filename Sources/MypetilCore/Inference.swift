import CoreGraphics

extension LayoutTree {
    /// Rebuilds a tree from where windows are right now, so starting mypetil keeps an
    /// arrangement instead of reshuffling it.
    ///
    /// Windows sharing (almost) the same frame become a tab group; the first of them in
    /// `windows` (front-most) is the active tab. The rest is split recursively wherever a
    /// straight cut separates the windows; the ratios reproduce the current sizes. Windows
    /// that overlap without a clean cut are separated by their centres.
    ///
    /// Replaces the tree's contents.
    ///
    /// - Parameter windows: Front to back.
    public func rebuild(from windows: [(id: WindowID, frame: CGRect)], in bounds: CGRect,
                        options: LayoutOptions = .init()) {
        root = Inference(options: options).build(Inference.clusters(of: windows, options: options), in: bounds)
    }
}

private struct Inference {
    /// One tile: a window or a tab group, with the frame of the whole tile.
    struct Cluster {
        var windows: [WindowID]
        var frame: CGRect
        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    }

    let options: LayoutOptions
    /// Slack for windows that are not exactly where a layout would put them.
    static let tolerance: CGFloat = 12

    static func clusters(of windows: [(id: WindowID, frame: CGRect)], options: LayoutOptions) -> [Cluster] {
        var clusters: [Cluster] = []
        for w in windows {
            if let i = clusters.firstIndex(where: { isClose($0.frame, w.frame) }) {
                clusters[i].windows.append(w.id)
            } else {
                clusters.append(Cluster(windows: [w.id], frame: w.frame))
            }
        }
        // A tab group's strip sits above its windows and belongs to the tile.
        return clusters.map { c in
            guard c.windows.count > 1 || options.showTabBarForSingleWindow else { return c }
            var c = c
            c.frame = CGRect(x: c.frame.minX, y: c.frame.minY - options.tabBarHeight,
                             width: c.frame.width, height: c.frame.height + options.tabBarHeight)
            return c
        }
    }

    func build(_ clusters: [Cluster], in rect: CGRect) -> Node? {
        guard let first = clusters.first else { return nil }
        if clusters.count == 1 { return GroupNode(first.windows) }
        let (axis, a, b, cut) = cleanCut(clusters) ?? centreCut(clusters, in: rect)
        let total = axis == .horizontal ? rect.width : rect.height
        let start = axis == .horizontal ? rect.minX : rect.minY
        let available = max(1, total - options.gap)
        let lengthA = min(max(cut - options.gap / 2 - start, 0), available)
        let (rectA, rectB) = split(rect, axis: axis, lengthA: lengthA)
        guard let nodeA = build(a, in: rectA), let nodeB = build(b, in: rectB) else {
            return build(a, in: rect) ?? build(b, in: rect)
        }
        let ratio = min(0.95, max(0.05, Double(lengthA / available)))
        return SplitNode(axis: axis, ratio: ratio, first: nodeA, second: nodeB)
    }

    /// A straight line with every tile entirely on one side, horizontal cuts tried first.
    /// Returns the two sides (left/top first) and the line's position.
    private func cleanCut(_ clusters: [Cluster]) -> (Axis, [Cluster], [Cluster], CGFloat)? {
        for axis in [Axis.horizontal, .vertical] {
            let lo: (CGRect) -> CGFloat = { axis == .horizontal ? $0.minX : $0.minY }
            let hi: (CGRect) -> CGFloat = { axis == .horizontal ? $0.maxX : $0.maxY }
            let sorted = clusters.sorted { lo($0.frame) < lo($1.frame) }
            var reach = -CGFloat.infinity
            for i in 0..<(sorted.count - 1) {
                reach = max(reach, hi(sorted[i].frame))
                let next = lo(sorted[i + 1].frame)
                if reach <= next + Self.tolerance {
                    return (axis, Array(sorted[...i]), Array(sorted[(i + 1)...]), (reach + next) / 2)
                }
            }
        }
        return nil
    }

    /// Overlapping windows: split along the longer side of `rect` by the windows' centres.
    private func centreCut(_ clusters: [Cluster], in rect: CGRect) -> (Axis, [Cluster], [Cluster], CGFloat) {
        let axis: Axis = rect.width >= rect.height ? .horizontal : .vertical
        let pos: (Cluster) -> CGFloat = { axis == .horizontal ? $0.center.x : $0.center.y }
        let sorted = clusters.sorted { pos($0) < pos($1) }
        let half = sorted.count / 2
        let middle = axis == .horizontal ? rect.midX : rect.midY
        return (axis, Array(sorted[..<half]), Array(sorted[half...]), middle)
    }

    private func split(_ rect: CGRect, axis: Axis, lengthA: CGFloat) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            return (CGRect(x: rect.minX, y: rect.minY, width: lengthA, height: rect.height),
                    CGRect(x: rect.minX + lengthA + options.gap, y: rect.minY,
                           width: max(0, rect.width - lengthA - options.gap), height: rect.height))
        case .vertical:
            return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: lengthA),
                    CGRect(x: rect.minX, y: rect.minY + lengthA + options.gap,
                           width: rect.width, height: max(0, rect.height - lengthA - options.gap)))
        }
    }

    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
