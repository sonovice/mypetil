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

    struct Tab: Equatable {
        let title: String
        let icon: NSImage?
    }

    /// AX coordinates.
    let frame: CGRect
    let style: Style
    /// The windows of the tile; more than one makes it a tab group.
    let tabs: [Tab]
    let activeIndex: Int
    /// Height of the tab strip at the top of the tile (0 without one).
    var tabBarHeight: CGFloat = 0

    var active: Tab { tabs[min(activeIndex, tabs.count - 1)] }
}

/// Shows gesture previews: frames only, no live window content, so dragging stays instant.
@MainActor
final class OverlayController {
    private var pool: [(panel: ChromePanel, host: NSHostingView<OverlayItemView>)] = []
    private var shown: [OverlayItem] = []
    /// Corner radius of app windows, so previews have the same shape as the windows.
    var cornerRadius: CGFloat = 10

    func show(_ items: [OverlayItem]) {
        guard items != shown else { return }
        shown = items
        while pool.count < items.count {
            let panel = ChromePanel(level: .popUpMenu, clickThrough: true)
            let host = NSHostingView(rootView: OverlayItemView(item: nil, cornerRadius: 0))
            panel.contentView = host
            pool.append((panel, host))
        }
        // Lower styles first so the target ends up on top.
        let ordered = items.sorted { $0.style.zOrder < $1.style.zOrder }
        for (i, entry) in pool.enumerated() {
            if i < ordered.count {
                entry.host.rootView = OverlayItemView(item: ordered[i], cornerRadius: cornerRadius)
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
        let host = NSHostingView(rootView: OverlayItemView(item: nil, cornerRadius: 0))
        panel.contentView = host
        return (panel, host)
    }()

    /// - Parameter translucent: For a window being dragged, so what lies below stays visible.
    func showGhost(_ item: OverlayItem, animated: Bool, translucent: Bool = false) {
        let (panel, host) = ghost
        panel.alphaValue = translucent ? 0.7 : 1
        if host.rootView.item?.style != item.style || host.rootView.item?.tabs != item.tabs
            || host.rootView.item?.activeIndex != item.activeIndex {
            host.rootView = OverlayItemView(item: item, cornerRadius: cornerRadius)
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
    let cornerRadius: CGFloat

    var body: some View {
        if let item {
            // Exactly the window's frame and corner shape.
            let shape = RoundedRectangle(cornerRadius: cornerRadius)
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
                VStack(spacing: 0) {
                    if item.tabs.count > 1 { tabStrip(item).frame(height: max(item.tabBarHeight - 2, 24)) }
                    label(item).frame(maxHeight: .infinity)
                }
            }
        }
    }

    /// The group's tabs, laid out like its real tab strip.
    private func tabStrip(_ item: OverlayItem) -> some View {
        HStack(spacing: 2) {
            ForEach(item.tabs.indices, id: \.self) { i in
                let isActive = i == item.activeIndex
                HStack(spacing: 5) {
                    if let icon = item.tabs[i].icon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    Text(item.tabs[i].title)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(isActive ? .primary : .secondary)
                .background(isActive ? Color.accentColor.opacity(0.28) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(4)
    }

    private func label(_ item: OverlayItem) -> some View {
        VStack(spacing: 6) {
            if let icon = item.active.icon {
                Image(nsImage: icon).resizable().frame(width: 40, height: 40)
            }
            Text(item.active.title)
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

    /// - Parameter window: The framed window; the border sits right above it. Nil (gesture
    ///   previews) puts it on top of everything.
    func show(around frame: CGRect, width: CGFloat, windowCornerRadius: CGFloat, animated: Bool = false,
              above window: CGWindowID? = nil) {
        view.configure(lineWidth: width, windowCornerRadius: windowCornerRadius)
        panel.setAXFrame(frame.insetBy(dx: -width, dy: -width), animated: animated && panel.isVisible)
        panel.order(above: window)
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
