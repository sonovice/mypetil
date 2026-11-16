import AppKit
import MypetilCore

/// Global mouse handling via a CGEvent tap:
///
/// - ⌥ + left drag: move a window; the overlay shows where it lands (edge → split, middle → tab).
/// - ⌥ + right drag: resize; corner cells move the corner, edge cells move that edge.
/// - Click on a tab strip: activate that tab. Drag a tab: move that window, no ⌥ needed.
///
/// Events belonging to these gestures are swallowed so the app below never sees them.
@MainActor
final class MouseController {
    private enum State {
        case idle
        case tabPressed(CGWindowID, at: CGPoint)
        case moving(CGWindowID, plan: DropPlan?)
        case resizing
    }

    private let wm: WindowManager
    private var tap: CFMachPort?
    private var state = State.idle
    private static let escapeKeyCode: Int64 = 53

    init(wm: WindowManager) {
        self.wm = wm
    }

    /// Fails if Accessibility permission is missing.
    func start() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mouseTapCallback,
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
        let flags = event.flags
        let optionOnly = flags.contains(.maskAlternate) && !flags.contains(.maskCommand) && !flags.contains(.maskControl)

        // A lost mouse-up (e.g. the tap was briefly disabled) must not leave a gesture stuck.
        if type == .leftMouseDown || type == .rightMouseDown { resetGesture(at: point) }

        switch (type, state) {
        case (.leftMouseDown, .idle):
            if let tab = wm.tab(at: point) {
                state = .tabPressed(tab, at: point)
                return nil
            }
            if optionOnly, let id = Self.windowUnder(point), wm.isManaged(id) {
                state = .moving(id, plan: nil)
                return nil
            }

        case (.leftMouseDragged, .tabPressed(let id, let start)):
            if hypot(point.x - start.x, point.y - start.y) > 5 { updateMove(id, at: point, previous: nil) }
            return nil

        case (.leftMouseDragged, .moving(let id, let plan)):
            updateMove(id, at: point, previous: plan)
            return nil

        case (.leftMouseUp, .tabPressed(let id, _)):
            state = .idle
            wm.focus(id)
            return nil

        case (.leftMouseUp, .moving(let id, let plan)):
            state = .idle
            wm.overlay.hide()
            if let plan { wm.performDrop(id, plan: plan) }
            return nil

        case (.rightMouseDown, .idle):
            if optionOnly, let id = Self.windowUnder(point), wm.isManaged(id), wm.beginResize(id, at: point) {
                state = .resizing
                return nil
            }

        case (.rightMouseDragged, .resizing):
            wm.updateResize(to: point)
            return nil

        case (.rightMouseUp, .resizing):
            state = .idle
            wm.endResize(at: point)
            return nil

        case (.keyDown, .moving):
            if event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode {
                state = .idle
                wm.overlay.hide()
                return nil
            }

        default:
            break
        }
        return pass
    }

    private func resetGesture(at point: CGPoint) {
        switch state {
        case .idle, .tabPressed: break
        case .moving: wm.overlay.hide()
        case .resizing: wm.endResize(at: point)
        }
        state = .idle
    }

    private func updateMove(_ id: CGWindowID, at point: CGPoint, previous: DropPlan?) {
        let plan = wm.dropPlan(for: id, at: point)
        if plan != previous {
            if let plan { wm.overlay.show(plan.preview, isTab: plan.isTab) } else { wm.overlay.hide() }
        }
        state = .moving(id, plan: plan)
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

private func mouseTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                              _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<MouseController>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { controller.handle(type, event) }
}
