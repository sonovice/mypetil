import AppKit
import Observation
import SwiftUI

struct SidebarItem: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let appName: String
    let icon: NSImage
    let isFocused: Bool
    /// False for tabs hidden behind another tab of their group.
    let isActiveTab: Bool
    let isFloating: Bool
    let isMinimized: Bool
}

/// One tile: a single window or a tab group.
struct SidebarGroup: Identifiable, Equatable {
    let items: [SidebarItem]
    var id: CGWindowID { items.first?.id ?? 0 }
    var isTabGroup: Bool { items.count > 1 }
}

struct SidebarContent: Equatable {
    var tiled: [SidebarGroup] = []
    /// Floating, minimized and hidden windows.
    var other: [SidebarItem] = []
}

struct SidebarActions {
    var focus: (CGWindowID) -> Void = { _ in }
    var toggleFloating: (CGWindowID) -> Void = { _ in }
    var minimize: (CGWindowID) -> Void = { _ in }
    var close: (CGWindowID) -> Void = { _ in }
}

@Observable
final class SidebarModel {
    var content = SidebarContent()
    var actions = SidebarActions()
}

/// One sidebar per display, pinned to its left edge (the tiling area starts right of it).
@MainActor
final class SidebarController {
    var actions = SidebarActions() {
        didSet { sidebars.values.forEach { $0.model.actions = actions } }
    }
    private var sidebars: [CGDirectDisplayID: (panel: ChromePanel, model: SidebarModel)] = [:]

    func sync(_ workspaces: [Workspace]) {
        let ids = Set(workspaces.map(\.displayID))
        for (id, entry) in sidebars where !ids.contains(id) {
            entry.panel.orderOut(nil)
            sidebars[id] = nil
        }
        for ws in workspaces {
            let entry = sidebars[ws.displayID] ?? makeSidebar()
            sidebars[ws.displayID] = entry
            entry.panel.setAXFrame(ws.sidebarFrame)
            entry.panel.orderFrontRegardless()
        }
    }

    func update(_ content: [CGDirectDisplayID: SidebarContent]) {
        for (id, entry) in sidebars {
            let new = content[id] ?? SidebarContent()
            if entry.model.content != new { entry.model.content = new }
        }
    }

    private func makeSidebar() -> (panel: ChromePanel, model: SidebarModel) {
        let model = SidebarModel()
        model.actions = actions
        let panel = ChromePanel(level: .floating, clickThrough: false)
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .active
        let host = FirstClickHostingView(rootView: SidebarView(model: model))
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        panel.contentView = background
        host.frame = background.bounds
        return (panel, model)
    }
}

// MARK: - Views

struct SidebarView: View {
    let model: SidebarModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.content.tiled) { group in
                    if group.isTabGroup {
                        TabGroupRows(group: group, actions: model.actions)
                    } else if let item = group.items.first {
                        SidebarRow(item: item, actions: model.actions)
                    }
                }
                if !model.content.other.isEmpty {
                    Text("Nicht gekachelt")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .padding(.top, 10)
                        .padding(.leading, 8)
                    ForEach(model.content.other) { item in
                        SidebarRow(item: item, actions: model.actions)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
    }
}

/// Tabs of one group: a light frame with a guide line, rows slightly indented.
private struct TabGroupRows: View {
    let group: SidebarGroup
    let actions: SidebarActions

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(group.items) { item in
                SidebarRow(item: item, actions: actions)
            }
        }
        .padding(.leading, 7)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 2)
                .padding(.vertical, 6)
                .padding(.leading, 2)
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.vertical, 2)
    }
}

private struct SidebarRow: View {
    let item: SidebarItem
    let actions: SidebarActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 12, weight: item.isFocused ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.title != item.appName {
                    Text(item.appName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if item.isMinimized {
                Image(systemName: "minus.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else if item.isFloating {
                Image(systemName: "macwindow.on.rectangle").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(item.isMinimized ? 0.5 : (item.isActiveTab ? 1 : 0.7))
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { actions.focus(item.id) }
        .help("\(item.title) — \(item.appName)")
        .contextMenu {
            Button("Fokussieren") { actions.focus(item.id) }
            Button(item.isFloating ? "Kacheln" : "Schweben lassen") { actions.toggleFloating(item.id) }
            Button(item.isMinimized ? "Wiederherstellen" : "Minimieren") { actions.minimize(item.id) }
            Divider()
            Button("Schließen") { actions.close(item.id) }
        }
    }

    private var rowBackground: Color {
        if item.isFocused { return Color.accentColor.opacity(0.25) }
        if hovering { return Color.primary.opacity(0.07) }
        return .clear
    }
}
