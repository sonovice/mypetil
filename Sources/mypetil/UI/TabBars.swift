import AppKit
import SwiftUI

/// The tab strip above a tab group.
struct TabStrip {
    struct Tab {
        let window: ManagedWindow
        let isActive: Bool
    }

    /// AX coordinates.
    let frame: CGRect
    /// Where the group's active window sits, below the strip.
    let windowFrame: CGRect
    let tabs: [Tab]
    let hasFocus: Bool
    /// The windows' corner radius; the strip's top corners use it too.
    let cornerRadius: CGFloat

    /// The strip's background continues behind the top of the window, so the window's
    /// rounded corners show the strip instead of a gap: strip and window read as one shape.
    var panelFrame: CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width,
               height: max(frame.height, windowFrame.minY + cornerRadius - frame.minY))
    }

    /// Diameter of a tab's close button. It sits at the trailing end, as far from the tab's
    /// edge as from the strip's top and bottom, in a square hit area as tall as the strip.
    static let closeButtonSize: CGFloat = 18

    /// Tabs share the width equally, so hit testing is plain arithmetic.
    func hit(at point: CGPoint) -> TabHit? {
        guard frame.contains(point), !tabs.isEmpty else { return nil }
        let width = frame.width / CGFloat(tabs.count)
        let index = min(max(Int((point.x - frame.minX) / width), 0), tabs.count - 1)
        let tabMaxX = frame.minX + width * CGFloat(index + 1)
        return TabHit(window: tabs[index].window.id, isCloseButton: point.x >= tabMaxX - frame.height)
    }
}

/// What a click on a tab strip hit.
struct TabHit {
    let window: CGWindowID
    let isCloseButton: Bool
}

/// Shows one panel per tab group. The panels only draw; clicks and drags on them are
/// handled by the mouse event tap so a tab can be dragged out like a window.
@MainActor
final class TabBarController {
    private var panels: [(panel: ChromePanel, host: NSHostingView<TabStripView>)] = []
    private var strips: [TabStrip] = []

    func show(_ newStrips: [TabStrip]) {
        strips = newStrips
        while panels.count < strips.count {
            let panel = ChromePanel(level: .normal, clickThrough: true)
            let host = NSHostingView(rootView: TabStripView(strip: nil))
            panel.contentView = host
            panels.append((panel, host))
        }
        for (i, entry) in panels.enumerated() {
            if i < strips.count {
                entry.host.rootView = TabStripView(strip: strips[i])
                entry.panel.setAXFrame(strips[i].panelFrame)
                // Below the window, which covers the extended background.
                if let active = strips[i].tabs.first(where: \.isActive)?.window.id {
                    entry.panel.order(below: active)
                } else {
                    entry.panel.orderFrontRegardless()
                }
            } else {
                entry.panel.orderOut(nil)
            }
        }
    }

    func hit(at point: CGPoint) -> TabHit? {
        strips.lazy.compactMap { $0.hit(at: point) }.first
    }
}

struct TabStripView: View {
    let strip: TabStrip?

    var body: some View {
        if let strip {
            let r = strip.cornerRadius
            GeometryReader { geo in
                let width = geo.size.width / CGFloat(max(strip.tabs.count, 1))
                HStack(spacing: 0) {
                    ForEach(strip.tabs.indices, id: \.self) { i in
                        TabView(tab: strip.tabs[i], groupHasFocus: strip.hasFocus, height: strip.frame.height,
                                // The outer tabs' highlights follow the strip's rounded corners.
                                leadingRadius: i == 0 ? r : 0,
                                trailingRadius: i == strip.tabs.count - 1 ? r : 0)
                            .frame(width: width, height: strip.frame.height)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r))
        }
    }
}

private struct TabView: View {
    let tab: TabStrip.Tab
    let groupHasFocus: Bool
    let height: CGFloat
    var leadingRadius: CGFloat = 0
    var trailingRadius: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: tab.window.icon)
                .resizable()
                .frame(width: 18, height: 18)
            Text(tab.window.displayTitle)
                .font(.system(size: 12.5, weight: tab.isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tab.isActive ? .secondary : .tertiary)
                .frame(width: TabStrip.closeButtonSize, height: TabStrip.closeButtonSize)
                .background(Color.primary.opacity(tab.isActive ? 0.08 : 0), in: Circle())
        }
        .padding(.leading, 10)
        // Same distance to the tab's right edge as to the strip's top and bottom.
        .padding(.trailing, max(0, (height - TabStrip.closeButtonSize) / 2))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(tab.isActive ? .primary : .secondary)
        .background {
            if tab.isActive {
                // Concentric with the strip: 3 pt inside, so 3 pt less radius.
                UnevenRoundedRectangle(topLeadingRadius: max(6, leadingRadius - 3), bottomLeadingRadius: 6,
                                       bottomTrailingRadius: 6, topTrailingRadius: max(6, trailingRadius - 3))
                    .fill(groupHasFocus ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.10))
                    .padding(3)
            }
        }
        .help(tab.window.displayTitle)
    }
}
