import AppKit

/// The translucent rectangle that shows where a dragged window will land.
/// Deliberately no live window preview: just a frame, so dragging stays instant.
@MainActor
final class DropOverlay {
    private let panel = ChromePanel(level: .popUpMenu, clickThrough: true)
    private let view = OverlayView()
    private var current: CGRect?

    init() {
        panel.contentView = view
    }

    func show(_ frame: CGRect, isTab: Bool) {
        if view.isTab != isTab {
            view.isTab = isTab
            view.needsDisplay = true
        }
        guard current != frame || !panel.isVisible else { return }
        current = frame
        panel.setAXFrame(frame)
        panel.orderFrontRegardless()
    }

    func hide() {
        current = nil
        panel.orderOut(nil)
    }
}

private final class OverlayView: NSView {
    var isTab = false

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let box = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        accent.withAlphaComponent(0.16).setFill()
        path.fill()
        accent.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 3
        path.stroke()

        if isTab {
            // A tab-shaped hint along the top edge plus a label.
            let tabRect = NSRect(x: box.minX + 12, y: box.maxY - 30, width: min(160, box.width - 24), height: 22)
            accent.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: tabRect, xRadius: 6, yRadius: 6).fill()
            label("Als Tab hinzufügen", in: box)
        }
    }

    private func label(_ text: String, in box: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pill = NSRect(x: box.midX - size.width / 2 - 14, y: box.midY - size.height / 2 - 8,
                          width: size.width + 28, height: size.height + 16)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + 14, y: pill.minY + 8), withAttributes: attrs)
    }
}
