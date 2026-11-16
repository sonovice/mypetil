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
    let isZoomed: Bool
    let isMinimized: Bool
    let isFullScreen: Bool
}

/// One tile: a single window or a tab group.
struct SidebarGroup: Identifiable, Equatable {
    let items: [SidebarItem]
    var id: CGWindowID { items.first?.id ?? 0 }
    var isTabGroup: Bool { items.count > 1 }
}

/// Windows on another desktop of the same display.
struct SpaceSection: Identifiable, Equatable {
    let id: Spaces.ID
    let title: String
    let items: [SidebarItem]
}

struct SidebarContent: Equatable {
    var tiled: [SidebarGroup] = []
    /// Floating, minimized, hidden and full-screen windows.
    var other: [SidebarItem] = []
    var otherSpaces: [SpaceSection] = []
}

struct SidebarActions {
    var focus: (CGWindowID) -> Void = { _ in }
    var toggleFloating: (CGWindowID) -> Void = { _ in }
    var toggleZoom: (CGWindowID) -> Void = { _ in }
    var minimize: (CGWindowID) -> Void = { _ in }
    var close: (CGWindowID) -> Void = { _ in }
    var openSettings: () -> Void = {}
    /// New width while dragging the edge; `final` on release.
    var resize: (_ width: CGFloat, _ final: Bool) -> Void = { _, _ in }
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
    private var sidebars: [CGDirectDisplayID: Sidebar] = [:]
    private var frames: [CGDirectDisplayID: CGRect] = [:]

    private struct Sidebar {
        let panel: ChromePanel
        let background: SidebarBackground
        let model: SidebarModel
        let handle: SidebarResizeHandle
    }

    func sync(_ workspaces: [Workspace], width: CGFloat, cornerRadius: CGFloat, color: NSColor?) {
        let ids = Set(workspaces.map(\.displayID))
        for (id, sidebar) in sidebars where !ids.contains(id) {
            sidebar.panel.orderOut(nil)
            sidebars[id] = nil
        }
        for ws in workspaces {
            let sidebar = sidebars[ws.displayID] ?? makeSidebar()
            sidebars[ws.displayID] = sidebar
            frames[ws.displayID] = ws.sidebarFrame
            sidebar.handle.currentWidth = width
            sidebar.background.cornerRadius = cornerRadius
            sidebar.background.fill = color
            sidebar.panel.setAXFrame(ws.sidebarFrame)
            sidebar.panel.orderFrontRegardless()
        }
    }

    /// Resizes only the sidebars while the edge is being dragged; tiles follow on release.
    func preview(width: CGFloat) {
        for (id, sidebar) in sidebars {
            guard var frame = frames[id] else { continue }
            frame.size.width = width
            sidebar.panel.setAXFrame(frame)
        }
    }

    func update(_ content: [CGDirectDisplayID: SidebarContent]) {
        for (id, sidebar) in sidebars {
            let new = content[id] ?? SidebarContent()
            if sidebar.model.content != new { sidebar.model.content = new }
        }
    }

    private func makeSidebar() -> Sidebar {
        let model = SidebarModel()
        model.actions = actions
        let panel = ChromePanel(level: .floating, clickThrough: false)
        let background = SidebarBackground()
        let host = FirstClickHostingView(rootView: SidebarView(model: model))
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        let handle = SidebarResizeHandle()
        handle.onResize = { [weak self] width, final in self?.actions.resize(width, final) }
        handle.autoresizingMask = [.minXMargin, .height]
        background.addSubview(handle)
        panel.contentView = background
        host.frame = background.bounds
        handle.frame = NSRect(x: background.bounds.maxX - SidebarResizeHandle.width, y: 0,
                              width: SidebarResizeHandle.width, height: background.bounds.height)
        return Sidebar(panel: panel, background: background, model: model, handle: handle)
    }
}

/// Sidebar material whose two corners away from the screen edge are rounded like app
/// windows, with the same hairline outline. An optional solid fill replaces the material.
final class SidebarBackground: NSVisualEffectView {
    var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    /// Covers the material; the appearance follows it so text stays legible.
    var fill: NSColor? {
        didSet {
            guard fill != oldValue else { return }
            fillView.layer?.backgroundColor = fill?.cgColor
            fillView.isHidden = fill == nil
            appearance = fill.flatMap { NSAppearance(named: $0.isDark ? .darkAqua : .aqua) }
        }
    }
    private let fillView = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .sidebar
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.masksToBounds = true
        // Right-hand corners; the left ones sit at the screen edge.
        layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        layer?.borderWidth = 1
        updateBorderColor()
        fillView.wantsLayer = true
        fillView.isHidden = true
        fillView.frame = bounds
        fillView.autoresizingMask = [.width, .height]
        addSubview(fillView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

extension NSColor {
    /// "#RRGGBB" (the "#" is optional).
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let byte = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    /// Relative luminance below the midpoint: light text reads better on it.
    var isDark: Bool {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5
    }
}

/// The sidebar's right edge, which can be dragged to change the width.
final class SidebarResizeHandle: NSView {
    static let width: CGFloat = 6
    var onResize: ((CGFloat, Bool) -> Void)?
    var currentWidth: CGFloat = 220
    private var dragStart: (mouseX: CGFloat, width: CGFloat)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .activeAlways: mypetil is a background app, its windows are never key.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved,
                                                               .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseExited(with event: NSEvent) { if dragStart == nil { NSCursor.arrow.set() } }

    override func mouseDown(with event: NSEvent) {
        dragStart = (NSEvent.mouseLocation.x, currentWidth)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        NSCursor.resizeLeftRight.set()
        onResize?(start.width + NSEvent.mouseLocation.x - start.mouseX, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        dragStart = nil
        onResize?(start.width + NSEvent.mouseLocation.x - start.mouseX, true)
    }
}

// MARK: - Views

struct SidebarView: View {
    let model: SidebarModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(model.content.tiled) { group in
                        if group.isTabGroup {
                            TabGroupRows(group: group, actions: model.actions)
                        } else if let item = group.items.first {
                            SidebarRow(item: item, actions: model.actions)
                        }
                    }
                    if !model.content.other.isEmpty {
                        SectionHeader("Nicht gekachelt").padding(.top, 10)
                        ForEach(model.content.other) { item in
                            SidebarRow(item: item, actions: model.actions)
                        }
                    }
                    ForEach(model.content.otherSpaces) { space in
                        SectionHeader(space.title).padding(.top, 10)
                        ForEach(space.items) { item in
                            SidebarRow(item: item, actions: model.actions)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            Divider()
            BottomBar(openSettings: model.actions.openSettings)
        }
    }
}

/// Finder-style section title.
private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .padding(.bottom, 3)
            .padding(.top, 2)
    }
}

/// Tabs of one group: indented below a thin guide line, like a disclosed outline item.
private struct TabGroupRows: View {
    let group: SidebarGroup
    let actions: SidebarActions

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(group.items) { item in
                SidebarRow(item: item, actions: actions)
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 2)
                .padding(.vertical, 5)
                .padding(.leading, 5)
        }
        .padding(.vertical, 2)
    }
}

private struct SidebarRow: View {
    let item: SidebarItem
    let actions: SidebarActions
    @State private var hovering = false

    static let height: CGFloat = 38

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.title != item.appName {
                    Text(item.appName)
                        .font(.system(size: 11))
                        .foregroundStyle(item.isFocused ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let badge {
                Image(systemName: badge)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(item.isFocused ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
            }
        }
        .foregroundStyle(item.isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        // Room for title and subtitle, so rows without a subtitle line up with the rest.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .opacity(item.isMinimized ? 0.5 : (item.isActiveTab || item.isFocused ? 1 : 0.75))
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { actions.focus(item.id) }
        .help("\(item.title) — \(item.appName)")
        .contextMenu {
            Button("Fokussieren") { actions.focus(item.id) }
            if !item.isFloating, !item.isMinimized, !item.isFullScreen {
                Button(item.isZoomed ? "Maximierung aufheben" : "Maximieren") { actions.toggleZoom(item.id) }
            }
            Button(item.isFloating ? "Kacheln" : "Schweben lassen") { actions.toggleFloating(item.id) }
            Button(item.isMinimized ? "Wiederherstellen" : "Minimieren") { actions.minimize(item.id) }
            Divider()
            Button("Schließen") { actions.close(item.id) }
        }
    }

    private var badge: String? {
        if item.isFullScreen { return "arrow.up.left.and.arrow.down.right" }
        if item.isMinimized { return "minus" }
        if item.isZoomed { return "plus.magnifyingglass" }
        if item.isFloating { return "macwindow.on.rectangle" }
        return nil
    }

    private var rowBackground: Color {
        if item.isFocused { return .accentColor }
        if hovering { return Color.primary.opacity(0.06) }
        return .clear
    }
}

private struct BottomBar: View {
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Einstellungen")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
