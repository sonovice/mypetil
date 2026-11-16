import AppKit
import MypetilCore

/// A window mypetil knows about (tiled, floating or minimized).
final class ManagedWindow {
    let id: CGWindowID
    let element: AXUIElement
    let pid: pid_t
    let app: NSRunningApplication?
    var title: String
    /// Not part of the layout tree; the user positions it freely.
    var isFloating: Bool
    var isMinimized: Bool

    init(id: CGWindowID, element: AXUIElement, pid: pid_t, isFloating: Bool) {
        self.id = id
        self.element = element
        self.pid = pid
        self.app = NSRunningApplication(processIdentifier: pid)
        self.title = element.string(kAXTitleAttribute) ?? ""
        self.isFloating = isFloating
        self.isMinimized = element.bool(kAXMinimizedAttribute) ?? false
    }

    var appName: String { app?.localizedName ?? "?" }
    var bundleID: String? { app?.bundleIdentifier }
    var icon: NSImage { app?.icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)! }
    /// What to show as the window's name.
    var displayTitle: String { title.isEmpty ? appName : title }
}

/// Identifies a workspace: one macOS Space on one display.
struct WorkspaceKey: Hashable {
    let displayID: CGDirectDisplayID
    let spaceID: Spaces.ID
}

/// One Space on one display: its geometry and its layout tree.
final class Workspace {
    let key: WorkspaceKey
    var displayID: CGDirectDisplayID { key.displayID }
    /// Desktop number as shown by Mission Control.
    var spaceNumber = 0
    let tree = LayoutTree()
    var layout: LayoutResult = .empty
    /// A maximized window: covers the whole tiling area on top of the other tiles.
    var zoomed: CGWindowID?
    /// Full display frame (AX coordinates).
    private(set) var screenFrame: CGRect = .zero
    /// Display minus menu bar and Dock.
    private(set) var visibleFrame: CGRect = .zero
    private(set) var sidebarFrame: CGRect = .zero
    /// Where tiles go: visible frame minus sidebar and outer gap.
    private(set) var tilingBounds: CGRect = .zero

    init(key: WorkspaceKey) {
        self.key = key
    }

    func update(screen: NSScreen, config: Config) {
        screenFrame = Screens.toAX(screen.frame)
        visibleFrame = Screens.toAX(screen.visibleFrame)
        sidebarFrame = CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                              width: config.sidebarWidth, height: visibleFrame.height)
        tilingBounds = CGRect(x: visibleFrame.minX + config.sidebarWidth, y: visibleFrame.minY,
                              width: visibleFrame.width - config.sidebarWidth, height: visibleFrame.height)
            // Tiles reach the menu bar and the bottom edge; only the sides keep a margin.
            .insetBy(dx: config.outerGap, dy: 0)
    }
}

/// Where a dragged window will land.
struct DropPlan: Equatable {
    enum Target: Equatable {
        case window(CGWindowID, Zone)
        case emptyWorkspace
    }

    let workspace: Workspace
    let target: Target
    /// Final tile of the dragged window, shown as overlay.
    let preview: CGRect
    /// The workspace's layout after the drop.
    let result: LayoutResult

    var isTab: Bool { if case .window(_, .center) = target { true } else { false } }

    static func == (a: DropPlan, b: DropPlan) -> Bool {
        a.workspace === b.workspace && a.target == b.target && a.preview == b.preview
    }
}
