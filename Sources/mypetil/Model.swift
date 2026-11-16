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

/// One display: its geometry and its layout tree.
final class Workspace {
    let displayID: CGDirectDisplayID
    let tree = LayoutTree()
    var layout: LayoutResult = .empty
    /// Full display frame (AX coordinates).
    private(set) var screenFrame: CGRect = .zero
    /// Display minus menu bar and Dock.
    private(set) var visibleFrame: CGRect = .zero
    private(set) var sidebarFrame: CGRect = .zero
    /// Where tiles go: visible frame minus sidebar and outer gap.
    private(set) var tilingBounds: CGRect = .zero

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func update(screen: NSScreen, config: Config) {
        screenFrame = Screens.toAX(screen.frame)
        visibleFrame = Screens.toAX(screen.visibleFrame)
        sidebarFrame = CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                              width: config.sidebarWidth, height: visibleFrame.height)
        tilingBounds = CGRect(x: visibleFrame.minX + config.sidebarWidth, y: visibleFrame.minY,
                              width: visibleFrame.width - config.sidebarWidth, height: visibleFrame.height)
            .insetBy(dx: config.outerGap, dy: config.outerGap)
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

    var isTab: Bool { if case .window(_, .center) = target { true } else { false } }

    static func == (a: DropPlan, b: DropPlan) -> Bool {
        a.workspace === b.workspace && a.target == b.target && a.preview == b.preview
    }
}
