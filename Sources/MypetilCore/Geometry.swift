import CoreGraphics

/// Identifies a window. On macOS this is the `CGWindowID`.
public typealias WindowID = UInt32

/// All geometry in MypetilCore uses the Accessibility / CoreGraphics convention:
/// origin at the top-left of the primary display, y grows downwards.
/// "top" therefore means smaller y.

/// How a split arranges its two children.
public enum Axis: Sendable, Equatable, Codable {
    /// Children side by side: first is left, second is right.
    case horizontal
    /// Children stacked: first is top, second is bottom.
    case vertical

    public var flipped: Axis { self == .horizontal ? .vertical : .horizontal }
}

/// Where a dragged window is released relative to the window below the cursor.
public enum Zone: Sendable, Equatable, CaseIterable {
    case left, right, top, bottom
    /// Released in the middle: join the target as a tab.
    case center

    var axis: Axis? {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        case .center: nil
        }
    }

    /// Whether the dropped window becomes the first child of the new split.
    var insertsFirst: Bool { self == .left || self == .top }

    /// Classifies a point inside `frame`.
    ///
    /// The central rectangle (covering `centerFraction` of each dimension) is the
    /// tab zone. Outside of it, the nearest edge wins.
    public static func at(_ point: CGPoint, in frame: CGRect, centerFraction: CGFloat = 0.4) -> Zone {
        guard frame.width > 0, frame.height > 0 else { return .center }
        let nx = (point.x - frame.minX) / frame.width
        let ny = (point.y - frame.minY) / frame.height
        let lo = (1 - centerFraction) / 2
        let hi = 1 - lo
        if nx >= lo, nx <= hi, ny >= lo, ny <= hi { return .center }
        let distances: [(Zone, CGFloat)] = [(.left, nx), (.right, 1 - nx), (.top, ny), (.bottom, 1 - ny)]
        return distances.min { $0.1 < $1.1 }!.0
    }
}

/// Direction for keyboard navigation.
public enum Direction: Sendable, Equatable {
    case left, right, up, down
}

extension CGRect {
    /// Rounds each edge independently so neighbouring rects keep sharing exact borders.
    var pixelAligned: CGRect {
        let x0 = minX.rounded(), y0 = minY.rounded()
        let x1 = maxX.rounded(), y1 = maxY.rounded()
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}

/// Which edges of a window follow the mouse during a resize drag.
///
/// The window is divided into a 3×3 grid: corner cells grab the corner (two edges),
/// edge cells grab that edge only, and the middle cell grabs the nearest corner.
public struct ResizeEdges: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let left = ResizeEdges(rawValue: 1 << 0)
    public static let right = ResizeEdges(rawValue: 1 << 1)
    public static let top = ResizeEdges(rawValue: 1 << 2)
    public static let bottom = ResizeEdges(rawValue: 1 << 3)

    public static func at(_ point: CGPoint, in frame: CGRect) -> ResizeEdges {
        guard frame.width > 0, frame.height > 0 else { return [.right, .bottom] }
        let nx = (point.x - frame.minX) / frame.width
        let ny = (point.y - frame.minY) / frame.height
        var edges: ResizeEdges = []
        if nx < 1.0 / 3 { edges.insert(.left) } else if nx > 2.0 / 3 { edges.insert(.right) }
        if ny < 1.0 / 3 { edges.insert(.top) } else if ny > 2.0 / 3 { edges.insert(.bottom) }
        if edges.isEmpty {
            edges = [nx < 0.5 ? .left : .right, ny < 0.5 ? .top : .bottom]
        }
        return edges
    }

    /// `frame` with the grabbed edges moved by `delta`, never smaller than `minimum`.
    public func apply(to frame: CGRect, delta: CGVector, minimum: CGFloat = 50) -> CGRect {
        var x0 = frame.minX, x1 = frame.maxX, y0 = frame.minY, y1 = frame.maxY
        if contains(.left) { x0 = min(x0 + delta.dx, x1 - minimum) }
        if contains(.right) { x1 = max(x1 + delta.dx, x0 + minimum) }
        if contains(.top) { y0 = min(y0 + delta.dy, y1 - minimum) }
        if contains(.bottom) { y1 = max(y1 + delta.dy, y0 + minimum) }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
