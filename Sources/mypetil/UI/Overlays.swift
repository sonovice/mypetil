import AppKit
import SwiftUI

/// One rectangle drawn during a mouse gesture.
struct OverlayItem: Equatable {
    enum Style: Equatable {
        /// The window being dragged or resized, where it is now.
        case source
        /// Where the window will end up.
        case target
        /// Where the window will end up, as a new tab.
        case tabTarget
        /// Another window that moves or changes size as a consequence.
        case affected
    }

    /// AX coordinates.
    let frame: CGRect
    let style: Style
    let title: String
    let icon: NSImage?
}

/// Shows gesture previews: frames only, no live window content, so dragging stays instant.
@MainActor
final class OverlayController {
    private var pool: [(panel: ChromePanel, host: NSHostingView<OverlayItemView>)] = []
    private var shown: [OverlayItem] = []

    func show(_ items: [OverlayItem]) {
        guard items != shown else { return }
        shown = items
        while pool.count < items.count {
            let panel = ChromePanel(level: .popUpMenu, clickThrough: true)
            let host = NSHostingView(rootView: OverlayItemView(item: nil))
            panel.contentView = host
            pool.append((panel, host))
        }
        // Lower styles first so the target ends up on top.
        let ordered = items.sorted { $0.style.zOrder < $1.style.zOrder }
        for (i, entry) in pool.enumerated() {
            if i < ordered.count {
                entry.host.rootView = OverlayItemView(item: ordered[i])
                entry.panel.setAXFrame(ordered[i].frame)
                entry.panel.orderFrontRegardless()
            } else {
                entry.panel.orderOut(nil)
            }
        }
    }

    func hide() { show([]) }
}

private extension OverlayItem.Style {
    var zOrder: Int {
        switch self {
        case .affected: 0
        case .source: 1
        case .target, .tabTarget: 2
        }
    }
}

struct OverlayItemView: View {
    let item: OverlayItem?

    var body: some View {
        if let item {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            ZStack {
                switch item.style {
                case .source:
                    shape.fill(Color.black.opacity(0.12))
                    shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 5]))
                case .target, .tabTarget:
                    shape.fill(Color.accentColor.opacity(0.22))
                    shape.strokeBorder(Color.accentColor, lineWidth: 3)
                case .affected:
                    shape.fill(.ultraThinMaterial)
                    shape.strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
                }
                if item.style != .source {
                    label(item)
                }
            }
            .padding(2)
        }
    }

    private func label(_ item: OverlayItem) -> some View {
        VStack(spacing: 6) {
            if let icon = item.icon {
                Image(nsImage: icon).resizable().frame(width: 40, height: 40)
            }
            Text(item.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if item.style == .tabTarget {
                Text("Als Tab hinzufügen")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(16)
    }
}

/// Coloured frame around the focused tiled window, drawn in the gap just outside it.
@MainActor
final class FocusBorder {
    private let panel = ChromePanel(level: .normal, clickThrough: true)
    private let view = BorderView()

    init() {
        panel.contentView = view
    }

    func show(around frame: CGRect, width: CGFloat, windowCornerRadius: CGFloat) {
        if view.lineWidth != width || view.windowCornerRadius != windowCornerRadius {
            view.lineWidth = width
            view.windowCornerRadius = windowCornerRadius
            view.needsDisplay = true
        }
        panel.setAXFrame(frame.insetBy(dx: -width, dy: -width))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

private final class BorderView: NSView {
    var lineWidth: CGFloat = 2
    var windowCornerRadius: CGFloat = 10

    override func draw(_ dirtyRect: NSRect) {
        // The stroke's centre line runs lineWidth/2 outside the window edge, so its radius
        // is the window's plus that distance: the ring stays concentric with the corner.
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = windowCornerRadius + lineWidth / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = lineWidth
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
