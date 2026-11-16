import AppKit
import ApplicationServices

/// Private, used by yabai for the same purpose: builds an AX element from a raw token.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// Apps only list the windows of the current desktop in `kAXWindowsAttribute`. Windows on
/// other desktops are found the way yabai does it: by building the AX elements of an app
/// directly from their (small, sequential) element ids and asking each whether it is a window.
enum RemoteWindows {
    /// Element ids are probed up to this bound; real apps stay far below it.
    private static let maxElementID: UInt64 = 0x7FFF

    /// The AX elements of `wanted` windows of `pid`. Stops as soon as all are found.
    /// Blocks on the app's AX server: call it off the main thread.
    static func find(_ wanted: Set<CGWindowID>, of pid: pid_t) -> [CGWindowID: AXUIElement] {
        var found: [CGWindowID: AXUIElement] = [:]
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: 0, toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: 0x636F_636F, toByteOffset: 8, as: Int32.self)   // "coco"
        }
        for elementID in 0..<maxElementID where found.count < wanted.count {
            token.withUnsafeMutableBytes { $0.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self) }
            guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue(),
                  element.string(kAXRoleAttribute) == kAXWindowRole,
                  let id = element.windowID, wanted.contains(id) else { continue }
            found[id] = element
        }
        return found
    }
}
