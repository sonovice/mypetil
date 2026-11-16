import AppKit
import SwiftUI

/// One rectangle drawn during a mouse gesture.
struct OverlayItem: Equatable {
    enum Style: Equatable {
        /// A window shown as a tile with its icon and title.
        case window
        /// The dragged window over a tile it would join as a tab.
        case tabTarget
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

    func hide() {
        show([])
        hideGhost()
    }

    // MARK: Ghost

    /// The dragged window's preview tile: glued to the mouse, then snapped onto its landing spot.
    private lazy var ghost: (panel: ChromePanel, host: NSHostingView<OverlayItemView>) = {
        let panel = ChromePanel(level: .popUpMenu, clickThrough: true)
        let host = NSHostingView(rootView: OverlayItemView(item: nil))
        panel.contentView = host
        return (panel, host)
    }()

    func showGhost(_ item: OverlayItem, animated: Bool) {
        let (panel, host) = ghost
        if host.rootView.item?.style != item.style || host.rootView.item?.title != item.title {
            host.rootView = OverlayItemView(item: item)
        }
        panel.setAXFrame(item.frame, animated: animated && panel.isVisible)
        panel.orderFrontRegardless()
    }

    func hideGhost() { ghost.panel.orderOut(nil) }
}

private extension OverlayItem.Style {
    var zOrder: Int {
        switch self {
        case .window: 0
        case .tabTarget: 1
        }
    }
}

struct OverlayItemView: View {
    let item: OverlayItem?

    var body: some View {
        if let item {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
                label(item)
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

/// Coloured frame around the focused window, drawn just outside it. While a window is
/// dragged with ⌥ it travels with the mouse and snaps onto the landing spot.
@MainActor
final class FocusBorder {
    private let panel = ChromePanel(level: .normal, clickThrough: true)
    private let view = BorderView()

    init() {
        panel.contentView = view
    }

    func show(around frame: CGRect, width: CGFloat, windowCornerRadius: CGFloat, animated: Bool = false) {
        view.configure(lineWidth: width, windowCornerRadius: windowCornerRadius)
        panel.setAXFrame(frame.insetBy(dx: -width, dy: -width), animated: animated && panel.isVisible)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

/// A layer border: it follows the view's size on its own, also during frame animations.
private final class BorderView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(lineWidth: CGFloat, windowCornerRadius: CGFloat) {
        guard let layer else { return }
        layer.borderWidth = lineWidth
        // The border is drawn inside the layer, so its inner edge has the window's radius:
        // the ring stays concentric with the window corner.
        layer.cornerRadius = windowCornerRadius + lineWidth
        layer.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}
