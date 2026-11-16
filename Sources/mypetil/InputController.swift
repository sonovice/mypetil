import AppKit
import Carbon.HIToolbox
import MypetilCore

/// Global input via one CGEvent tap:
///
/// - ⌥ + left drag: move a window. Overlays mark the dragged window, where it lands
///   (edge → split, middle → tab) and which windows move as a result.
/// - ⌥ + right drag: resize. Corner cells move the corner, edge cells move that edge.
///   Only a preview is shown; the layout changes when the button is released.
/// - Click on a tab strip: activate that tab (or close it via its ×). Drag a tab: move
///   that window, no ⌥ needed.
/// - ⌃⌥G: float / tile the focused window. ⌃⌥M: maximize it within the tiling area (not
///   native full screen). ⌃⌥ + other keys: the user's launchers. Esc cancels a gesture.
///
/// Events belonging to these gestures are swallowed so the app below never sees them.
@MainActor
final class InputController {
    private enum State {
        case idle
        case tabPressed(TabHit, at: CGPoint)
        /// Left button down on a window without modifiers: maybe the start of a title-bar drag.
        /// `last` is the latest position the app has seen.
        case windowPressed(CGWindowID, at: CGPoint, frame: CGRect, last: CGPoint)
        /// A mypetil move. For a hijacked title-bar drag, `releaseAt` is where the app gets
        /// its mouse-up, so the system's drag ends where it was stopped.
        case moving(releaseAt: CGPoint?)
        /// A floating window moved or resized natively; only the border is ours.
        case followingDrag(CGWindowID, at: CGPoint, frame: CGRect, edges: ResizeEdges)
        /// A mypetil resize (⌥ + right drag, or a hijacked edge drag; see `moving`).
        case resizing(releaseAt: CGPoint?)
        /// A gesture cancelled with Esc: the rest of the drag is swallowed.
        case cancelled(releaseAt: CGPoint?)
    }

    private let wm: WindowManager
    private var tap: CFMachPort?
    private var state = State.idle {
        didSet { updateWatchdog() }
    }
    /// Runs while a gesture is active, see `checkButtons`.
    private var watchdog: Timer?

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
                state = .moving(releaseAt: nil)
                wm.beginMove(id, at: point, windowFrame: wm.frame(of: id))
                return nil
            }
            if flags.isEmpty, let id = Self.windowUnder(point), wm.isManaged(id), let frame = wm.frame(of: id) {
                state = .windowPressed(id, at: point, frame: frame, last: point)
            }

        case (.leftMouseDragged, .tabPressed(let tab, let start)):
            if hypot(point.x - start.x, point.y - start.y) > 5 {
                state = .moving(releaseAt: nil)
                wm.beginMove(tab.window, at: start, windowFrame: wm.frame(of: tab.window))
                wm.updateMove(at: point)
            }
            return nil

        case (.leftMouseDragged, .windowPressed(let id, let start, let frame, let last)):
            return systemDrag(id, start: start, frame: frame, last: last, point: point, event: event)

        case (.leftMouseDragged, .moving):
            wm.updateMove(at: point)
            return nil

        case (.leftMouseDragged, .followingDrag(let id, let start, let frame, let edges)):
            let delta = CGVector(dx: point.x - start.x, dy: point.y - start.y)
            wm.followSystemDrag(id, windowFrame: edges.apply(to: frame, delta: delta))

        case (.leftMouseDragged, .cancelled), (.rightMouseDragged, .cancelled):
            return nil

        case (.leftMouseUp, .tabPressed(let tab, _)):
            state = .idle
            if tab.isCloseButton { wm.close(tab.window) } else { wm.focus(tab.window) }
            return nil

        case (.leftMouseUp, .moving(let releaseAt)):
            state = .idle
            wm.endMove()
            return release(event, at: releaseAt)

        case (.leftMouseUp, .cancelled(let releaseAt)), (.rightMouseUp, .cancelled(let releaseAt)):
            state = .idle
            return release(event, at: releaseAt)

        case (.leftMouseUp, .followingDrag):
            state = .idle
            wm.endSystemDrag()

        case (.leftMouseUp, .windowPressed):
            state = .idle

        case (.rightMouseDown, .idle):
            if flags == .maskAlternate, let id = Self.windowUnder(point), wm.isManaged(id), wm.beginResize(id, at: point) {
                state = .resizing(releaseAt: nil)
                return nil
            }

        case (.rightMouseDragged, .resizing), (.leftMouseDragged, .resizing):
            wm.updateResize(at: point)
            return nil

        case (.rightMouseUp, .resizing(let releaseAt)), (.leftMouseUp, .resizing(let releaseAt)):
            state = .idle
            wm.endResize()
            return release(event, at: releaseAt)

        case (.keyDown, _):
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if key == kVK_Escape, case .moving(let releaseAt) = state {
                wm.cancelGesture()
                state = .cancelled(releaseAt: releaseAt)
                return nil
            }
            if key == kVK_Escape, case .resizing(let releaseAt) = state {
                wm.cancelGesture()
                state = .cancelled(releaseAt: releaseAt)
                return nil
            }
            if flags == [.maskControl, .maskAlternate], let command = shortcut(for: key) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { command() }
                return nil
            }

        default:
            break
        }
        return pass
    }

    /// What ⌃⌥ + `key` does: mypetil's own commands first, then the user's launchers.
    private func shortcut(for key: Int) -> (() -> Void)? {
        switch key {
        case kVK_ANSI_G: return { [wm] in wm.toggleFloating() }
        case kVK_ANSI_M: return { [wm] in wm.toggleZoom() }
        default:
            guard let launcher = wm.config.launchers.first(where: { $0.keyCode == key }) else { return nil }
            return { launcher.open() }
        }
    }

    /// Decides whether a plain drag on a window is the system moving it (title bar) or
    /// resizing it (edge), by watching which of its edges follow the mouse; that works
    /// whatever the app's title bar looks like. Tiled windows are then taken over by mypetil
    /// (same previews as ⌥-drag / ⌥-resize); floating ones keep their native behaviour, with
    /// the border following the mouse.
    private func systemDrag(_ id: CGWindowID, start: CGPoint, frame: CGRect, last: CGPoint,
                              point: CGPoint, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let distance = hypot(point.x - start.x, point.y - start.y)
        guard distance > 4 else {
            state = .windowPressed(id, at: start, frame: frame, last: point)
            return pass
        }
        guard let now = wm.frame(of: id) else {
            state = .idle
            return pass
        }
        var changed: ResizeEdges = []
        if abs(now.minX - frame.minX) > 1 { changed.insert(.left) }
        if abs(now.maxX - frame.maxX) > 1 { changed.insert(.right) }
        if abs(now.minY - frame.minY) > 1 { changed.insert(.top) }
        if abs(now.maxY - frame.maxY) > 1 { changed.insert(.bottom) }
        let sameSize = abs(now.width - frame.width) < 2 && abs(now.height - frame.height) < 2
        guard !changed.isEmpty else {
            // Selecting text, dragging a file …: not ours. Give up once clearly something else.
            state = distance > 40 ? .idle : .windowPressed(id, at: start, frame: frame, last: point)
            return pass
        }
        // A move shifts every edge alike; a resize moves only the grabbed ones.
        let edges: ResizeEdges = sameSize ? [.left, .right, .top, .bottom] : changed
        if wm.isTiled(id) {
            if sameSize {
                state = .moving(releaseAt: last)
                wm.beginTitleBarMove(id, grabbedAt: start, windowFrame: frame)
                wm.updateMove(at: point)
            } else {
                state = .resizing(releaseAt: last)
                wm.beginEdgeResize(id, grabbedAt: start, edges: edges, windowFrame: frame)
                wm.updateResize(at: point)
            }
            return nil
        }
        state = .followingDrag(id, at: start, frame: frame, edges: edges)
        wm.followSystemDrag(id, windowFrame: edges.apply(to: frame, delta: CGVector(dx: point.x - start.x,
                                                                                      dy: point.y - start.y)))
        return pass
    }

    // MARK: Watchdog

    private var isInGesture: Bool {
        switch state {
        case .moving, .resizing, .followingDrag, .cancelled: true
        case .idle, .tabPressed, .windowPressed: false
        }
    }

    private func updateWatchdog() {
        if isInGesture, watchdog == nil {
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkButtons() }
            }
        } else if !isInGesture {
            watchdog?.invalidate()
            watchdog = nil
        }
    }

    /// A mouse-up the tap never saw (it is switched off by the system when a callback takes
    /// too long) would leave a gesture and its previews on screen. Once no button is down
    /// any more, the gesture ends as if it had been released.
    private func checkButtons() {
        let left = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let right = CGEventSource.buttonState(.combinedSessionState, button: .right)
        guard !left, !right else { return }
        switch state {
        case .moving: wm.endMove()
        case .resizing: wm.endResize()
        case .followingDrag: wm.endSystemDrag()
        case .idle, .tabPressed, .windowPressed, .cancelled: break
        }
        state = .idle
    }

    /// Ends a gesture's mouse-up: swallowed, or handed to the app at `point`.
    private func release(_ event: CGEvent, at point: CGPoint?) -> Unmanaged<CGEvent>? {
        guard let point else { return nil }
        event.location = point
        return Unmanaged.passUnretained(event)
    }

    private func reset() {
        switch state {
        case .moving, .resizing: wm.cancelGesture()
        case .followingDrag: wm.endSystemDrag()
        case .idle, .tabPressed, .windowPressed, .cancelled: break
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
