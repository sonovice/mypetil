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
    let tabs: [Tab]
    let hasFocus: Bool

    /// Tabs share the width equally, so hit testing is plain arithmetic.
    func window(at point: CGPoint) -> CGWindowID? {
        guard frame.contains(point), !tabs.isEmpty else { return nil }
        let index = Int((point.x - frame.minX) / (frame.width / CGFloat(tabs.count)))
        return tabs[min(max(index, 0), tabs.count - 1)].window.id
    }
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
                entry.panel.setAXFrame(strips[i].frame)
                entry.panel.orderFrontRegardless()
            } else {
                entry.panel.orderOut(nil)
            }
        }
    }

    func window(at point: CGPoint) -> CGWindowID? {
        strips.lazy.compactMap { $0.window(at: point) }.first
    }
}

struct TabStripView: View {
    let strip: TabStrip?

    var body: some View {
        if let strip {
            GeometryReader { geo in
                let width = geo.size.width / CGFloat(max(strip.tabs.count, 1))
                HStack(spacing: 0) {
                    ForEach(strip.tabs, id: \.window.id) { tab in
                        TabView(tab: tab, groupHasFocus: strip.hasFocus)
                            .frame(width: width, height: geo.size.height)
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct TabView: View {
    let tab: TabStrip.Tab
    let groupHasFocus: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: tab.window.icon)
                .resizable()
                .frame(width: 15, height: 15)
            Text(tab.window.displayTitle)
                .font(.system(size: 11.5, weight: tab.isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(tab.isActive ? .primary : .secondary)
        .background {
            if tab.isActive {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(groupHasFocus ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.10))
                    .padding(3)
            }
        }
        .help(tab.window.displayTitle)
    }
}
