import AppKit
import Carbon.HIToolbox

/// Global input via one CGEvent tap:
///
/// - ⌥ + left drag: move a window. Overlays mark the dragged window, where it lands
///   (edge → split, middle → tab) and which windows move as a result.
/// - ⌥ + right drag: resize. Corner cells move the corner, edge cells move that edge.
///   Only a preview is shown; the layout changes when the button is released.
/// - Click on a tab strip: activate that tab (or close it via its ×). Drag a tab: move
///   that window, no ⌥ needed.
/// - ⌃⌥G: float / tile the focused window. Esc cancels a gesture.
///
/// Events belonging to these gestures are swallowed so the app below never sees them.
@MainActor
final class InputController {
    private enum State {
        case idle
        case tabPressed(TabHit, at: CGPoint)
        case moving
        case resizing
    }

    private let wm: WindowManager
    private var tap: CFMachPort?
    private var state = State.idle

    init(wm: WindowManager) {
        self.wm = wm
    }

    /// Fails if Accessibility permission is missing.
    func start() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: inputTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        let point = event.location
        let flags = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])

        if type == .leftMouseDown { wm.noteMouse(down: true) }
        if type == .leftMouseUp { wm.noteMouse(down: false) }
        // A lost mouse-up (e.g. the tap was briefly disabled) must not leave a gesture stuck.
        if type == .leftMouseDown || type == .rightMouseDown { reset() }

        switch (type, state) {
        case (.leftMouseDown, .idle):
            // Only when nothing else (notification banner, popover, floating window) covers the strip.
            if let tab = wm.tab(at: point), Self.frontmostOwner(at: point) == getpid() {
                state = .tabPressed(tab, at: point)
                return nil
            }
            if flags == .maskAlternate, let id = Self.windowUnder(point), wm.isManaged(id) {
                state = .moving
                wm.beginMove(id)
                return nil
            }

        case (.leftMouseDragged, .tabPressed(let tab, let start)):
            if hypot(point.x - start.x, point.y - start.y) > 5 {
                state = .moving
                wm.beginMove(tab.window)
                wm.updateMove(at: point)
            }
            return nil

        case (.leftMouseDragged, .moving):
            wm.updateMove(at: point)
            return nil

        case (.leftMouseUp, .tabPressed(let tab, _)):
            state = .idle
            if tab.isCloseButton { wm.close(tab.window) } else { wm.focus(tab.window) }
            return nil

        case (.leftMouseUp, .moving):
            state = .idle
            wm.endMove()
            return nil

        case (.rightMouseDown, .idle):
            if flags == .maskAlternate, let id = Self.windowUnder(point), wm.isManaged(id), wm.beginResize(id, at: point) {
                state = .resizing
                return nil
            }

        case (.rightMouseDragged, .resizing):
            wm.updateResize(at: point)
            return nil

        case (.rightMouseUp, .resizing):
            state = .idle
            wm.endResize()
            return nil

        case (.keyDown, _):
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if key == kVK_Escape, case .moving = state {
                reset()
                return nil
            }
            if key == kVK_Escape, case .resizing = state {
                reset()
                return nil
            }
            if key == kVK_ANSI_G, flags == [.maskControl, .maskAlternate] {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { wm.toggleFloating() }
                return nil
            }

        default:
            break
        }
        return pass
    }

    private func reset() {
        switch state {
        case .moving, .resizing: wm.cancelGesture()
        case .idle, .tabPressed: break
        }
        state = .idle
    }

    /// The owner of the front-most visible window under `point`, across all window levels.
    private static func frontmostOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point) else { continue }
            return info[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }

    /// The front-most normal window under `point`, from any app but ours.
    private static func windowUnder(_ point: CGPoint) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let ownPID = getpid()
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point) else { continue }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
        return nil
    }
}

private func inputTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                              _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<InputController>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { controller.handle(type, event) }
}
