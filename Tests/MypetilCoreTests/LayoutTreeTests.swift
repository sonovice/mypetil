import CoreGraphics
import Testing
@testable import MypetilCore

private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
private let noGap = LayoutOptions(gap: 0, tabBarHeight: 20)

private func frame(_ w: WindowID, _ r: LayoutResult) -> CGRect? { r.group(containing: w)?.windowFrame }

@Suite struct InsertTests {
    @Test func firstWindowFillsBounds() {
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds)
        #expect(frame(1, t.layout(in: bounds, options: noGap)) == bounds)
    }

    @Test func newWindowSplitsAlongLongerSide() {
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds, options: noGap)
        t.insert(2, near: 1, bounds: bounds, options: noGap)   // 1000x600 -> side by side
        var r = t.layout(in: bounds, options: noGap)
        #expect(frame(1, r) == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(frame(2, r) == CGRect(x: 500, y: 0, width: 500, height: 600))

        t.insert(3, near: 2, bounds: bounds, options: noGap)   // 500x600 -> stacked
        r = t.layout(in: bounds, options: noGap)
        #expect(frame(2, r) == CGRect(x: 500, y: 0, width: 500, height: 300))
        #expect(frame(3, r) == CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    @Test func gapsSeparateTiles() {
        let t = LayoutTree()
        let opts = LayoutOptions(gap: 10)
        t.insert(1, near: nil, bounds: bounds, options: opts)
        t.insert(2, near: 1, bounds: bounds, options: opts)
        let r = t.layout(in: bounds, options: opts)
        #expect(frame(1, r) == CGRect(x: 0, y: 0, width: 495, height: 600))
        #expect(frame(2, r) == CGRect(x: 505, y: 0, width: 495, height: 600))
    }
}

@Suite struct RemoveTests {
    @Test func siblingTakesOverSpace() {
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds, options: noGap)
        t.insert(2, near: 1, bounds: bounds, options: noGap)
        t.insert(3, near: 2, bounds: bounds, options: noGap)
        t.remove(2)
        let r = t.layout(in: bounds, options: noGap)
        #expect(frame(3, r) == CGRect(x: 500, y: 0, width: 500, height: 600))
        t.remove(1)
        #expect(frame(3, t.layout(in: bounds, options: noGap)) == bounds)
        t.remove(3)
        #expect(t.isEmpty)
    }
}

@Suite struct DropTests {
    private func twoSideBySide() -> LayoutTree {
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds, options: noGap)
        t.insert(2, near: 1, bounds: bounds, options: noGap)
        return t
    }

    @Test func dropOnTopHalfSplitsTargetVertically() {
        let t = twoSideBySide()
        t.insert(3, near: 2, bounds: bounds, options: noGap)
        #expect(t.drop(3, onto: 1, zone: .top))
        let r = t.layout(in: bounds, options: noGap)
        #expect(frame(3, r) == CGRect(x: 0, y: 0, width: 500, height: 300))
        #expect(frame(1, r) == CGRect(x: 0, y: 300, width: 500, height: 300))
        #expect(frame(2, r) == CGRect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func dropOnLeftHalfPlacesWindowLeft() {
        let t = twoSideBySide()
        t.drop(2, onto: 1, zone: .left)
        let r = t.layout(in: bounds, options: noGap)
        #expect(frame(2, r) == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(frame(1, r) == CGRect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func dropInCenterCreatesTabs() {
        let t = twoSideBySide()
        t.drop(2, onto: 1, zone: .center)
        let r = t.layout(in: bounds, options: noGap)
        #expect(r.groups.count == 1)
        let g = r.groups[0]
        #expect(g.windows == [1, 2])
        #expect(g.activeWindow == 2)
        #expect(g.tabBarFrame == CGRect(x: 0, y: 0, width: 1000, height: 20))
        #expect(g.windowFrame == CGRect(x: 0, y: 20, width: 1000, height: 580))
    }

    @Test func dropOntoItselfIsNoop() {
        let t = twoSideBySide()
        #expect(!t.drop(1, onto: 1, zone: .left))
        #expect(t.windows == [1, 2])
    }

    @Test func draggingTabOutOfGroupSplitsIt() {
        let t = twoSideBySide()
        t.drop(2, onto: 1, zone: .center)
        #expect(t.drop(2, onto: 1, zone: .right))
        let r = t.layout(in: bounds, options: noGap)
        #expect(r.groups.count == 2)
        #expect(frame(2, r) == CGRect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func dropFromForeignTreeInsertsWindow() {
        let t = twoSideBySide()
        #expect(t.drop(99, onto: 2, zone: .bottom))
        #expect(frame(99, t.layout(in: bounds, options: noGap)) == CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    @Test func zoneClassification() {
        let f = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(Zone.at(CGPoint(x: 50, y: 50), in: f) == .center)
        #expect(Zone.at(CGPoint(x: 5, y: 50), in: f) == .left)
        #expect(Zone.at(CGPoint(x: 95, y: 40), in: f) == .right)
        #expect(Zone.at(CGPoint(x: 50, y: 4), in: f) == .top)
        #expect(Zone.at(CGPoint(x: 40, y: 99), in: f) == .bottom)
    }
}

@Suite struct TabTests {
    @Test func removingActiveTabActivatesNeighbor() {
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds)
        t.insert(2, near: 1, bounds: bounds)
        t.insert(3, near: 1, bounds: bounds)
        t.drop(2, onto: 1, zone: .center)
        t.drop(3, onto: 1, zone: .center)
        #expect(t.tabs(of: 1) == [1, 2, 3])
        #expect(t.isActiveTab(3))
        t.remove(3)
        #expect(t.isActiveTab(2))
        #expect(t.cycleTab(of: 2, by: 1) == 1)
        #expect(t.cycleTab(of: 1, by: -1) == 2)
    }
}

@Suite struct MinSizeTests {
    @Test func minimumWidthIsRespected() {
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds, options: noGap)
        t.insert(2, near: 1, bounds: bounds, options: noGap)
        let r = t.layout(in: bounds, minSizes: [2: CGSize(width: 700, height: 0)], options: noGap)
        #expect(frame(1, r) == CGRect(x: 0, y: 0, width: 300, height: 600))
        #expect(frame(2, r) == CGRect(x: 300, y: 0, width: 700, height: 600))
        #expect(!r.overflows)
    }

    @Test func nestedMinimumsPropagate() {
        // 1 | (2 / 3) where 3 needs 800 px width.
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds, options: noGap)
        t.insert(2, near: 1, bounds: bounds, options: noGap)
        t.insert(3, near: 2, bounds: bounds, options: noGap)
        let r = t.layout(in: bounds, minSizes: [3: CGSize(width: 800, height: 0)], options: noGap)
        #expect(frame(1, r)?.width == 200)
        #expect(frame(2, r)?.width == 800)
        #expect(frame(3, r)?.width == 800)
    }

    @Test func impossibleMinimumsShareProportionally() {
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds, options: noGap)
        t.insert(2, near: 1, bounds: bounds, options: noGap)
        let r = t.layout(in: bounds, minSizes: [1: CGSize(width: 900, height: 0),
                                                2: CGSize(width: 600, height: 0)], options: noGap)
        #expect(r.overflows)
        #expect(frame(1, r)?.width == 600)
        #expect(frame(2, r)?.width == 400)
    }

    @Test func tabBarCountsTowardsMinimumHeight() {
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds, options: noGap)
        t.insert(2, near: 1, bounds: bounds, options: noGap)
        t.toggleSplitAxis(of: 1)     // stack vertically
        t.insert(3, near: 1, bounds: bounds, options: noGap)
        t.drop(3, onto: 1, zone: .center)
        let r = t.layout(in: bounds, minSizes: [1: CGSize(width: 0, height: 400)], options: noGap)
        #expect(r.group(containing: 1)?.frame.height == 420)
    }
}

@Suite struct NavigationTests {
    @Test func neighborsFollowGeometry() {
        // 1 | (2 / 3)
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds, options: noGap)
        t.insert(2, near: 1, bounds: bounds, options: noGap)
        t.insert(3, near: 2, bounds: bounds, options: noGap)
        let r = t.layout(in: bounds, options: noGap)
        #expect(t.neighbor(of: 1, .right, in: r) == 2)
        #expect(t.neighbor(of: 3, .left, in: r) == 1)
        #expect(t.neighbor(of: 3, .up, in: r) == 2)
        #expect(t.neighbor(of: 2, .down, in: r) == 3)
        #expect(t.neighbor(of: 1, .left, in: r) == nil)
    }

    @Test func swapExchangesTiles() {
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds, options: noGap)
        t.insert(2, near: 1, bounds: bounds, options: noGap)
        t.swap(1, 2)
        #expect(frame(2, t.layout(in: bounds, options: noGap))?.minX == 0)
    }

    @Test func manualResizeMovesSplitBoundary() {
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds, options: noGap)
        t.insert(2, near: 1, bounds: bounds, options: noGap)
        t.applyManualResize(of: 1, from: CGRect(x: 0, y: 0, width: 500, height: 600),
                            to: CGRect(x: 0, y: 0, width: 600, height: 600), bounds: bounds, options: noGap)
        let r = t.layout(in: bounds, options: noGap)
        #expect(frame(1, r)?.width == 600)
        #expect(frame(2, r) == CGRect(x: 600, y: 0, width: 400, height: 600))
    }

    @Test func copyIsIndependent() {
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds)
        t.insert(2, near: 1, bounds: bounds)
        let c = t.copy()
        c.drop(2, onto: 1, zone: .center)
        #expect(t.layout(in: bounds).groups.count == 2)
        #expect(c.layout(in: bounds).groups.count == 1)
    }
}

@Suite struct ResizeEdgeTests {
    let f = CGRect(x: 0, y: 0, width: 300, height: 300)

    @Test func cornersGrabTwoEdges() {
        #expect(ResizeEdges.at(CGPoint(x: 10, y: 10), in: f) == [.left, .top])
        #expect(ResizeEdges.at(CGPoint(x: 290, y: 290), in: f) == [.right, .bottom])
    }

    @Test func edgeMiddlesGrabOneEdge() {
        #expect(ResizeEdges.at(CGPoint(x: 150, y: 10), in: f) == [.top])
        #expect(ResizeEdges.at(CGPoint(x: 290, y: 150), in: f) == [.right])
    }

    @Test func centerGrabsNearestCorner() {
        #expect(ResizeEdges.at(CGPoint(x: 140, y: 160), in: f) == [.left, .bottom])
    }

    @Test func applyMovesOnlyGrabbedEdges() {
        let r = ResizeEdges([.right, .bottom]).apply(to: f, delta: CGVector(dx: 20, dy: -10))
        #expect(r == CGRect(x: 0, y: 0, width: 320, height: 290))
    }

    @Test func cornerResizeMovesBothSplitBoundaries() {
        // 1 | (2 / 3): dragging 2's bottom-left corner moves the vertical and horizontal boundary.
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds, options: noGap)
        t.insert(2, near: 1, bounds: bounds, options: noGap)
        t.insert(3, near: 2, bounds: bounds, options: noGap)
        let old = CGRect(x: 500, y: 0, width: 500, height: 300)
        let new = ResizeEdges([.left, .bottom]).apply(to: old, delta: CGVector(dx: -100, dy: 50))
        t.applyManualResize(of: 2, from: old, to: new, bounds: bounds, options: noGap)
        let r = t.layout(in: bounds, options: noGap)
        #expect(frame(1, r)?.width == 400)
        #expect(frame(2, r) == CGRect(x: 400, y: 0, width: 600, height: 350))
        #expect(frame(3, r) == CGRect(x: 400, y: 350, width: 600, height: 250))
    }

    @Test func movingWithoutResizingKeepsTheLayout() {
        // A window dragged by its title bar (e.g. onto another display) is not a resize.
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds, options: noGap)
        t.insert(2, near: 1, bounds: bounds, options: noGap)
        let before = t.layout(in: bounds, options: noGap)
        let old = CGRect(x: 500, y: 0, width: 500, height: 600)
        t.applyManualResize(of: 2, from: old, to: old.offsetBy(dx: 1800, dy: -40), bounds: bounds, options: noGap)
        #expect(t.layout(in: bounds, options: noGap) == before)
    }
}

@Suite struct TabLifecycleTests {
    private func tabbed() -> LayoutTree {
        let t = LayoutTree()
        t.insert(1, near: nil, bounds: bounds, options: noGap)
        t.insert(2, near: 1, bounds: bounds, options: noGap)
        t.insert(3, near: 2, bounds: bounds, options: noGap)
        t.drop(2, onto: 1, zone: .center)
        t.drop(3, onto: 1, zone: .center)
        return t
    }

    @Test func droppingTabGroupMemberOntoAnotherGroupStaysFlat() {
        let t = tabbed()
        t.insert(4, near: 1, bounds: bounds, options: noGap)
        t.drop(5, onto: 4, zone: .center)
        t.drop(2, onto: 4, zone: .center)       // one tab moves, no nesting
        #expect(t.tabs(of: 4) == [4, 5, 2])
        #expect(t.tabs(of: 1) == [1, 3])
    }

    @Test func draggedOutTabBecomesPlainWindow() {
        let t = tabbed()
        t.drop(3, onto: 1, zone: .bottom)
        let r = t.layout(in: bounds, options: noGap)
        #expect(r.group(containing: 3)?.windows == [3])
        #expect(r.group(containing: 3)?.tabBarFrame == nil)
    }

    @Test func lastRemainingTabLosesTabBar() {
        let t = tabbed()
        t.drop(2, onto: 1, zone: .left)
        t.drop(3, onto: 1, zone: .right)
        let g = t.layout(in: bounds, options: noGap).group(containing: 1)
        #expect(g?.windows == [1])
        #expect(g?.tabBarFrame == nil)
        #expect(g?.windowFrame == g?.frame)
    }
}

@Suite struct ResizeThirdsTests {
    let f = CGRect(x: 100, y: 50, width: 900, height: 600)

    @Test(arguments: [0.0, 0.1, 0.2, 0.33])
    func wholeLeftThirdGrabsLeftEdge(nx: Double) {
        let p = CGPoint(x: f.minX + f.width * nx, y: f.midY)
        #expect(ResizeEdges.at(p, in: f) == [.left])
    }

    @Test(arguments: [0.67, 0.8, 0.99])
    func wholeRightThirdGrabsRightEdge(nx: Double) {
        let p = CGPoint(x: f.minX + f.width * nx, y: f.midY)
        #expect(ResizeEdges.at(p, in: f) == [.right])
    }

    @Test(arguments: [0.0, 0.2, 0.33])
    func wholeTopThirdGrabsTopEdge(ny: Double) {
        let p = CGPoint(x: f.midX, y: f.minY + f.height * ny)
        #expect(ResizeEdges.at(p, in: f) == [.top])
    }
}


@Suite struct InferenceTests {
    private let gapped = LayoutOptions(gap: 6, tabBarHeight: 20)

    /// Builds a layout, takes its frames as "the windows on screen" and infers it back.
    private func roundTrip(_ build: (LayoutTree) -> Void) -> (LayoutResult, LayoutResult) {
        let t = LayoutTree()
        build(t)
        let original = t.layout(in: bounds, options: gapped)
        let onScreen = original.groups.flatMap { g in g.windows.map { (id: $0, frame: g.windowFrame) } }
        let inferred = LayoutTree()
        inferred.rebuild(from: onScreen, in: bounds, options: gapped)
        return (original, inferred.layout(in: bounds, options: gapped))
    }

    @Test func reproducesNestedSplitsAndRatios() {
        let (original, inferred) = roundTrip { t in
            t.insert(1, near: nil, bounds: bounds, options: gapped)
            t.insert(2, near: 1, bounds: bounds, options: gapped)
            t.insert(3, near: 2, bounds: bounds, options: gapped)
            t.insert(4, near: 1, bounds: bounds, options: gapped)
            t.applyManualResize(of: 1, from: CGRect(x: 0, y: 0, width: 497, height: 297),
                                to: CGRect(x: 0, y: 0, width: 397, height: 297), bounds: bounds, options: gapped)
        }
        #expect(inferred == original)
    }

    @Test func sameFrameBecomesATabGroup() {
        let (original, inferred) = roundTrip { t in
            t.insert(1, near: nil, bounds: bounds, options: gapped)
            t.insert(2, near: 1, bounds: bounds, options: gapped)
            t.drop(3, onto: 2, zone: .center)
        }
        #expect(inferred.groups.map(\.frame) == original.groups.map(\.frame))
        #expect(Set(inferred.group(containing: 3)?.windows ?? []) == [2, 3])
    }

    @Test func frontMostTabIsActive() {
        let f = CGRect(x: 0, y: 20, width: 1000, height: 580)
        let t = LayoutTree()
        t.rebuild(from: [(id: 7, frame: f), (id: 5, frame: f)], in: bounds, options: gapped)
        #expect(t.layout(in: bounds, options: gapped).groups.first?.activeWindow == 7)
    }

    @Test func overlappingWindowsAreSeparated() {
        let t = LayoutTree()
        t.rebuild(from: [(id: 1, frame: CGRect(x: 100, y: 100, width: 600, height: 400)),
                         (id: 2, frame: CGRect(x: 300, y: 150, width: 600, height: 400))],
                  in: bounds, options: gapped)
        let r = t.layout(in: bounds, options: gapped)
        #expect(r.groups.count == 2)
        #expect(frame(1, r)!.maxX < frame(2, r)!.minX)
    }
}
