import AppKit
import ApplicationServices

/// Private but stable since 10.x and used by every macOS tiling WM (yabai, Amethyst, AeroSpace):
/// maps an AX window element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin, typed wrapper around the Accessibility C API.
extension AXUIElement {
    static func application(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    func raw(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success ? value : nil
    }

    func string(_ attribute: String) -> String? { raw(attribute) as? String }
    func bool(_ attribute: String) -> Bool? { (raw(attribute) as? NSNumber)?.boolValue }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = raw(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        (raw(attribute) as? [AnyObject])?.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        } ?? []
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, attribute as CFString, value) == .success
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(self, action as CFString) == .success
    }

    // MARK: Geometry (AX coordinates: top-left origin, y down)

    var position: CGPoint? {
        guard let value = raw(kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        guard let value = raw(kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    func setPosition(_ point: CGPoint) {
        var p = point
        if let value = AXValueCreate(.cgPoint, &p) { set(kAXPositionAttribute, value) }
    }

    func setSize(_ size: CGSize) {
        var s = size
        if let value = AXValueCreate(.cgSize, &s) { set(kAXSizeAttribute, value) }
    }
}

enum AXAttr {
    /// Undocumented app attribute. When enabled (e.g. by VoiceOver-ish tools) some apps animate
    /// every frame change, which makes tiling slow; we switch it off while moving windows.
    static let enhancedUserInterface = "AXEnhancedUserInterface"
    static let fullScreen = "AXFullScreen"
}
