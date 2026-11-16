import AppKit

// Read-only SkyLight (CoreGraphics Services) calls. Private but long-stable and used by
// yabai, Amethyst and others; none of them need SIP disabled.
private typealias CGSConnectionID = Int32
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?

/// macOS Spaces ("Schreibtische"), as far as a window manager needs them.
enum Spaces {
    typealias ID = UInt64

    struct Space {
        let id: ID
        /// 1-based number among the desktops of its display, as Mission Control shows it.
        let number: Int
        let isFullScreen: Bool
    }

    struct Display {
        /// UUID of the display, or "Main" when "Displays have separate Spaces" is off.
        let identifier: String
        let current: ID?
        let spaces: [Space]
    }

    private static let allSpacesMask: Int32 = 0x7
    private static let fullScreenType = 4

    static func displays() -> [Display] {
        guard let raw = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return raw.map { entry in
            var number = 0
            let spaces = (entry["Spaces"] as? [[String: Any]] ?? []).compactMap { s -> Space? in
                guard let id = (s["id64"] as? NSNumber)?.uint64Value else { return nil }
                let fullScreen = (s["type"] as? Int) == fullScreenType
                if !fullScreen { number += 1 }
                return Space(id: id, number: fullScreen ? 0 : number, isFullScreen: fullScreen)
            }
            let current = ((entry["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
            return Display(identifier: entry["Display Identifier"] as? String ?? "Main", current: current, spaces: spaces)
        }
    }

    /// The managed-space entry responsible for a screen.
    static func display(for screen: NSScreen, in displays: [Display]) -> Display? {
        let uuid = CGDisplayCreateUUIDFromDisplayID(screen.displayID)
            .map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
        return displays.first { $0.identifier == uuid } ?? displays.first { $0.identifier == "Main" } ?? displays.first
    }

    /// The Space a window lives on (nil for windows on all Spaces or unknown windows).
    static func space(of window: CGWindowID) -> ID? {
        let list = [NSNumber(value: window)] as CFArray
        guard let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), allSpacesMask, list)?
            .takeRetainedValue() as? [NSNumber], spaces.count == 1 else { return nil }
        return spaces[0].uint64Value
    }

    /// Whether the window still exists anywhere (on any Space, minimized or not).
    static func windowExists(_ window: CGWindowID) -> Bool {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]]
        return !(info?.isEmpty ?? true)
    }
}
