import AppKit
import ApplicationServices

/// Accessibility events the window manager reacts to.
enum WindowEvent {
    case windowCreated(pid: pid_t)
    case focusChanged(pid: pid_t)
    case appHidden(pid: pid_t)
    case appShown(pid: pid_t)
    case destroyed(CGWindowID)
    case moved(CGWindowID)
    case resized(CGWindowID)
    case minimized(CGWindowID)
    case deminimized(CGWindowID)
    case titleChanged(CGWindowID)
}

/// Subscribes to the Accessibility notifications of one application.
///
/// App-level notifications are decoded via the element's pid. Window-level notifications
/// carry the CGWindowID in the refcon, because a destroyed element can no longer be asked
/// for its id.
final class AppObserver {
    let pid: pid_t
    let app: AXUIElement
    private let observer: AXObserver
    private var watched: [CGWindowID: AXUIElement] = [:]

    /// Receives every event; set once by the window manager.
    nonisolated(unsafe) static var sink: ((WindowEvent) -> Void)?

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification,
    ]

    init?(pid: pid_t) {
        var observer: AXObserver?
        guard AXObserverCreate(pid, appObserverCallback, &observer) == .success, let observer else { return nil }
        self.pid = pid
        self.app = .application(pid)
        self.observer = observer
        var subscribed = 0
        for n in Self.appNotifications where AXObserverAddNotification(observer, app, n as CFString, nil) == .success {
            subscribed += 1
        }
        // Apps that are still launching refuse subscriptions; the caller retries later.
        guard subscribed > 0 else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    func watch(_ window: AXUIElement, id: CGWindowID) {
        guard watched[id] == nil else { return }
        watched[id] = window
        let refcon = UnsafeMutableRawPointer(bitPattern: UInt(id))
        for n in Self.windowNotifications {
            AXObserverAddNotification(observer, window, n as CFString, refcon)
        }
    }

    func unwatch(_ id: CGWindowID) {
        guard let window = watched.removeValue(forKey: id) else { return }
        for n in Self.windowNotifications {
            AXObserverRemoveNotification(observer, window, n as CFString)
        }
    }

    fileprivate static func decode(_ element: AXUIElement, _ name: String, _ refcon: UnsafeMutableRawPointer?) -> WindowEvent? {
        let windowID = refcon.map { CGWindowID(truncatingIfNeeded: UInt(bitPattern: $0)) }
        switch name {
        case kAXWindowCreatedNotification: return element.pid.map { .windowCreated(pid: $0) }
        case kAXFocusedWindowChangedNotification: return element.pid.map { .focusChanged(pid: $0) }
        case kAXApplicationHiddenNotification: return element.pid.map { .appHidden(pid: $0) }
        case kAXApplicationShownNotification: return element.pid.map { .appShown(pid: $0) }
        case kAXUIElementDestroyedNotification: return windowID.map { .destroyed($0) }
        case kAXWindowMovedNotification: return windowID.map { .moved($0) }
        case kAXWindowResizedNotification: return windowID.map { .resized($0) }
        case kAXWindowMiniaturizedNotification: return windowID.map { .minimized($0) }
        case kAXWindowDeminiaturizedNotification: return windowID.map { .deminimized($0) }
        case kAXTitleChangedNotification: return windowID.map { .titleChanged($0) }
        default: return nil
        }
    }
}

private func appObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                 _ refcon: UnsafeMutableRawPointer?) {
    guard let event = AppObserver.decode(element, notification as String, refcon) else { return }
    AppObserver.sink?(event)
}
