import AppKit
import MypetilCore

/// Owns all state: known windows, one layout tree per display, and the UI that mirrors it.
///
/// Everything runs on the main thread: AX observers, the event tap and hotkeys all
/// deliver on the main run loop.
@MainActor
final class WindowManager {
    private(set) var config: Config
    private(set) var windows: [CGWindowID: ManagedWindow] = [:]
    private(set) var workspaces: [Workspace] = []
    private(set) var focusedID: CGWindowID?

    private var observers: [pid_t: AppObserver] = [:]
    private var hiddenApps: Set<pid_t> = []
    /// Learned minimum sizes: windows that refused to become smaller than this.
    private var minSizes: [CGWindowID: CGSize] = [:]
    /// The frame the layout last asked for, per window.
    private var targetFrames: [CGWindowID: CGRect] = [:]
    /// The frame the window actually had right after we placed it.
    private var placedFrames: [CGWindowID: CGRect] = [:]
    /// Inactive tabs, parked off-screen.
    private var parkedTabs: Set<CGWindowID> = []
    /// Windows the user moved/resized with the mouse (as opposed to the app itself).
    private var touchedByUser: Set<CGWindowID> = []
    private var settleWork: [CGWindowID: DispatchWorkItem] = [:]
    private var layoutScheduled = false
    private var uiScheduled = false
    private var resize: ResizeSession?

    let overlay = DropOverlay()
    let tabBars = TabBarController()
    let sidebars = SidebarController()

    init(config: Config) {
        self.config = config
    }

    // MARK: - Lifecycle

    func start() {
        AppObserver.sink = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        sidebars.actions = SidebarActions(
            focus: { [weak self] in self?.focus($0) },
            toggleFloating: { [weak self] in self?.toggleFloating($0) },
            minimize: { [weak self] in self?.toggleMinimized($0) },
            close: { [weak self] in self?.close($0) }
        )
        rebuildWorkspaces()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.observe(app) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.forgetApp(app.processIdentifier) }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.scan(app.processIdentifier)
                self?.updateFocus(app.processIdentifier)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWorkspaces() }
        }

        for app in NSWorkspace.shared.runningApplications { observe(app) }
        if let front = NSWorkspace.shared.frontmostApplication { updateFocus(front.processIdentifier) }
        layoutNow()
    }

    /// Brings parked tabs back on screen so nothing is lost when mypetil quits.
    func restoreParkedWindows() {
        for ws in workspaces {
            for g in ws.layout.groups {
                for id in g.windows where parkedTabs.contains(id) {
                    if let w = windows[id] { setFrame(w, g.windowFrame) }
                }
            }
        }
        parkedTabs.removeAll()
    }

    // MARK: - Discovery

    private func observe(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil, !app.isTerminated else { return }
        guard let observer = AppObserver(pid: pid) else {
            // Freshly launched apps are not ready for AX yet.
            if attempt < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Double(1 << attempt)) { [weak self] in
                    self?.observe(app, attempt: attempt + 1)
                }
            }
            return
        }
        observers[pid] = observer
        if app.isHidden { hiddenApps.insert(pid) }
        scan(pid)
    }

    /// Syncs our window list for one app with what Accessibility reports.
    private func scan(_ pid: pid_t) {
        guard let observer = observers[pid] else { return }
        var seen = Set<CGWindowID>()
        for element in observer.app.elements(kAXWindowsAttribute) {
            guard let id = element.windowID else { continue }
            seen.insert(id)
            if windows[id] == nil { adopt(element, id: id, pid: pid) }
        }
        let vanished = windows.values.filter { $0.pid == pid && !seen.contains($0.id) }.map(\.id)
        vanished.forEach(forget)
        if !vanished.isEmpty { setNeedsLayout() }
    }

    private func adopt(_ element: AXUIElement, id: CGWindowID, pid: pid_t) {
        guard element.string(kAXRoleAttribute) == kAXWindowRole,
              element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole,
              element.bool(AXAttr.fullScreen) != true else { return }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let floating = !element.isSettable(kAXSizeAttribute) || config.floatingApps.contains(bundleID)
        let w = ManagedWindow(id: id, element: element, pid: pid, isFloating: floating)
        windows[id] = w
        observers[pid]?.watch(element, id: id)
        if isTileable(w) { tile(w) }
        setNeedsUI()
    }

    private func forget(_ id: CGWindowID) {
        guard let w = windows.removeValue(forKey: id) else { return }
        untile(id)
        observers[w.pid]?.unwatch(id)
        minSizes[id] = nil
        targetFrames[id] = nil
        placedFrames[id] = nil
        parkedTabs.remove(id)
        touchedByUser.remove(id)
        settleWork.removeValue(forKey: id)?.cancel()
        if focusedID == id { focusedID = nil }
        setNeedsUI()
    }

    private func forgetApp(_ pid: pid_t) {
        windows.values.filter { $0.pid == pid }.map(\.id).forEach(forget)
        observers[pid] = nil
        hiddenApps.remove(pid)
        setNeedsLayout()
    }

    // MARK: - Tiling

    private func isTileable(_ w: ManagedWindow) -> Bool {
        !w.isFloating && !w.isMinimized && !hiddenApps.contains(w.pid)
    }

    func workspace(containing id: CGWindowID) -> Workspace? {
        workspaces.first { $0.tree.contains(id) }
    }

    private func workspace(at point: CGPoint) -> Workspace? {
        workspaces.first { $0.screenFrame.contains(point) }
    }

    private var focusedWorkspace: Workspace? {
        focusedID.flatMap(workspace(containing:)) ?? workspace(at: Screens.mouseLocation) ?? workspaces.first
    }

    /// The display a non-tiled window belongs to (by its centre).
    private func workspace(showing w: ManagedWindow) -> Workspace? {
        if let ws = workspace(containing: w.id) { return ws }
        if let f = w.element.frame, let ws = workspace(at: CGPoint(x: f.midX, y: f.midY)) { return ws }
        return workspaces.first
    }

    /// Adds a window to the tree, splitting the focused tile (or the largest one).
    private func tile(_ w: ManagedWindow) {
        let ws = focusedWorkspace ?? workspace(showing: w)
        guard let ws else { return }
        let near = focusedID.flatMap { ws.tree.contains($0) ? $0 : nil }
        ws.tree.insert(w.id, near: near, bounds: ws.tilingBounds, minSizes: minSizes, options: config.layoutOptions)
        setNeedsLayout()
    }

    private func untile(_ id: CGWindowID) {
        workspace(containing: id)?.tree.remove(id)
        targetFrames[id] = nil
        if parkedTabs.remove(id) != nil, let w = windows[id], let ws = focusedWorkspace {
            // Bring it back from its parking spot.
            let f = ws.tilingBounds.insetBy(dx: ws.tilingBounds.width * 0.15, dy: ws.tilingBounds.height * 0.15)
            setFrame(w, f)
        }
        setNeedsLayout()
    }

    private func rebuildWorkspaces() {
        var old = Dictionary(workspaces.map { ($0.displayID, $0) }, uniquingKeysWith: { a, _ in a })
        workspaces = NSScreen.screens.map { screen in
            let ws = old.removeValue(forKey: screen.displayID) ?? Workspace(displayID: screen.displayID)
            ws.update(screen: screen, config: config)
            return ws
        }
        // Windows of disconnected displays move to the main display.
        if let main = workspaces.first {
            for orphan in old.values {
                for id in orphan.tree.windows {
                    main.tree.insert(id, near: nil, bounds: main.tilingBounds, minSizes: minSizes,
                                     options: config.layoutOptions)
                }
            }
        }
        targetFrames.removeAll()
        sidebars.sync(workspaces)
        setNeedsLayout()
    }

    // MARK: - Layout

    func setNeedsLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in self?.layoutNow() }
    }

    func layoutNow() {
        layoutScheduled = false
        for ws in workspaces { apply(ws) }
        setNeedsUI()
    }

    private func apply(_ ws: Workspace, learning: Bool = true) {
        ws.layout = ws.tree.layout(in: ws.tilingBounds, minSizes: minSizes, options: config.layoutOptions)
        var learnedSomething = false
        for g in ws.layout.groups {
            for (i, id) in g.windows.enumerated() {
                guard let w = windows[id] else { continue }
                if i == g.activeIndex {
                    learnedSomething = place(w, in: g.windowFrame) || learnedSomething
                } else {
                    park(w, on: ws)
                }
            }
        }
        // A window refused its tile: lay out once more with the new minimum.
        if learnedSomething, learning { apply(ws, learning: false) }
    }

    /// Moves a window into its tile. Returns true if it revealed a new minimum size.
    private func place(_ w: ManagedWindow, in frame: CGRect) -> Bool {
        if targetFrames[w.id] == frame, !parkedTabs.contains(w.id) { return false }
        parkedTabs.remove(w.id)
        targetFrames[w.id] = frame
        setFrame(w, frame)
        guard var actual = w.element.frame else { return false }
        let learned = learnMinimum(w.id, requested: frame.size, actual: actual.size)
        // Fixed-size windows that cannot fill their tile get centred in it.
        if !learned, actual.width < frame.width - 20 || actual.height < frame.height - 20 {
            let origin = CGPoint(x: frame.midX - actual.width / 2, y: frame.midY - actual.height / 2).rounded
            w.element.setPosition(origin)
            actual.origin = origin
        }
        placedFrames[w.id] = actual
        return learned
    }

    private func learnMinimum(_ id: CGWindowID, requested: CGSize, actual: CGSize) -> Bool {
        var m = minSizes[id] ?? .zero
        var changed = false
        if actual.width > requested.width + 2, actual.width > m.width { m.width = actual.width; changed = true }
        if actual.height > requested.height + 2, actual.height > m.height { m.height = actual.height; changed = true }
        if changed { minSizes[id] = m }
        return changed
    }

    /// Hides an inactive tab by moving it (almost) off-screen, like AeroSpace does.
    /// macOS keeps at least a pixel visible; minimizing instead would animate.
    private func park(_ w: ManagedWindow, on ws: Workspace) {
        guard !parkedTabs.contains(w.id) else { return }
        let size = w.element.size ?? CGSize(width: 800, height: 600)
        let s = ws.screenFrame
        let probeRight = CGPoint(x: s.maxX + 10, y: s.maxY - 10)
        let rightIsFree = !workspaces.contains { $0 !== ws && $0.screenFrame.contains(probeRight) }
        let origin = rightIsFree ? CGPoint(x: s.maxX - 1, y: s.maxY - 1) : CGPoint(x: s.minX - size.width + 1, y: s.maxY - 1)
        w.element.setPosition(origin)
        parkedTabs.insert(w.id)
        targetFrames[w.id] = CGRect(origin: origin, size: size)
        placedFrames[w.id] = w.element.frame
    }

    private func setFrame(_ w: ManagedWindow, _ frame: CGRect) {
        let app = observers[w.pid]?.app ?? .application(w.pid)
        let enhanced = app.bool(AXAttr.enhancedUserInterface) == true
        if enhanced { app.set(AXAttr.enhancedUserInterface, kCFBooleanFalse) }
        defer { if enhanced { app.set(AXAttr.enhancedUserInterface, kCFBooleanTrue) } }
        // Size first so the move is not clamped by the old size, then size again because
        // some apps constrain their size to the display they are currently on.
        w.element.setSize(frame.size)
        w.element.setPosition(frame.origin)
        w.element.setSize(frame.size)
    }

    // MARK: - AX events

    private func handle(_ event: WindowEvent) {
        switch event {
        case .windowCreated(let pid):
            scan(pid)
            // Some apps finish configuring new windows (subrole, size) a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.scan(pid) }
        case .focusChanged(let pid):
            updateFocus(pid)
        case .appHidden(let pid):
            hiddenApps.insert(pid)
            windows.values.filter { $0.pid == pid }.forEach { untileQuietly($0.id) }
            setNeedsLayout()
        case .appShown(let pid):
            hiddenApps.remove(pid)
            windows.values.filter { $0.pid == pid && isTileable($0) }.forEach(tile)
        case .destroyed(let id):
            forget(id)
            setNeedsLayout()
        case .moved(let id), .resized(let id):
            frameChanged(id)
        case .minimized(let id):
            windows[id]?.isMinimized = true
            untileQuietly(id)
            setNeedsLayout()
        case .deminimized(let id):
            guard let w = windows[id] else { return }
            w.isMinimized = false
            if isTileable(w), workspace(containing: id) == nil { tile(w) }
        case .titleChanged(let id):
            guard let w = windows[id] else { return }
            w.title = w.element.string(kAXTitleAttribute) ?? w.title
            setNeedsUI()
        }
    }

    /// Removes from the tree without moving the window (it is being hidden anyway).
    private func untileQuietly(_ id: CGWindowID) {
        workspace(containing: id)?.tree.remove(id)
        targetFrames[id] = nil
        parkedTabs.remove(id)
        setNeedsUI()
    }

    private func updateFocus(_ pid: pid_t) {
        guard let app = observers[pid]?.app,
              let id = app.element(kAXFocusedWindowAttribute)?.windowID,
              windows[id] != nil else { return }
        focusedID = id
        // Focusing a parked tab (e.g. via Cmd-Tab) makes it the visible one.
        if let ws = workspace(containing: id), ws.tree.activate(id) { setNeedsLayout() }
        setNeedsUI()
    }

    /// A window moved or resized without us asking. Wait until the user lets go, then react.
    private func frameChanged(_ id: CGWindowID) {
        guard resize == nil, workspace(containing: id) != nil,
              let placed = placedFrames[id], let actual = windows[id]?.element.frame,
              !actual.isClose(to: placed) else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 { touchedByUser.insert(id) }
        settleWork.removeValue(forKey: id)?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle(id) }
        settleWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func settle(_ id: CGWindowID) {
        settleWork[id] = nil
        if NSEvent.pressedMouseButtons & 1 != 0 {
            touchedByUser.insert(id)
            frameChangedRetry(id)
            return
        }
        guard let ws = workspace(containing: id), let placed = placedFrames[id],
              let actual = windows[id]?.element.frame else { return }
        let byUser = touchedByUser.remove(id) != nil
        guard !actual.isClose(to: placed) else { return }
        let resized = abs(actual.width - placed.width) > 2 || abs(actual.height - placed.height) > 2
        if byUser, resized, !parkedTabs.contains(id) {
            // Dragged a window edge: move the split boundaries with it.
            ws.tree.applyManualResize(of: id, from: placed, to: actual, bounds: ws.tilingBounds,
                                      minSizes: minSizes, options: config.layoutOptions)
        } else if !byUser, resized {
            // The app insisted on a different size: remember it as its minimum.
            _ = learnMinimum(id, requested: placed.size, actual: actual.size)
        }
        // Anything else (e.g. dragged by the title bar) snaps back.
        targetFrames[id] = nil
        layoutNow()
    }

    private func frameChangedRetry(_ id: CGWindowID) {
        let work = DispatchWorkItem { [weak self] in self?.settle(id) }
        settleWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - Commands

    func focus(_ id: CGWindowID) {
        guard let w = windows[id] else { return }
        if w.isMinimized { w.element.set(kAXMinimizedAttribute, kCFBooleanFalse) }
        if hiddenApps.contains(w.pid) { w.app?.unhide() }
        if let ws = workspace(containing: id), ws.tree.activate(id) { layoutNow() }
        w.element.set(kAXMainAttribute, kCFBooleanTrue)
        w.element.perform(kAXRaiseAction)
        (observers[w.pid]?.app ?? .application(w.pid)).set(kAXFrontmostAttribute, kCFBooleanTrue)
        focusedID = id
        setNeedsUI()
    }

    func focusNeighbor(_ direction: Direction) {
        guard let id = focusedID, let ws = workspace(containing: id),
              let next = ws.tree.neighbor(of: id, direction, in: ws.layout) else { return }
        focus(next)
    }

    func swapWithNeighbor(_ direction: Direction) {
        guard let id = focusedID, let ws = workspace(containing: id),
              let other = ws.tree.neighbor(of: id, direction, in: ws.layout) else { return }
        ws.tree.swap(id, other)
        layoutNow()
        focus(id)
    }

    func cycleTab(by offset: Int) {
        guard let id = focusedID, let ws = workspace(containing: id),
              let next = ws.tree.cycleTab(of: id, by: offset) else { return }
        layoutNow()
        focus(next)
    }

    func toggleSplitAxis() {
        guard let id = focusedID, let ws = workspace(containing: id) else { return }
        ws.tree.toggleSplitAxis(of: id)
        layoutNow()
    }

    func toggleFloating(_ id: CGWindowID? = nil) {
        guard let id = id ?? focusedID, let w = windows[id] else { return }
        if w.isFloating {
            w.isFloating = false
            if isTileable(w) { tile(w) }
        } else {
            w.isFloating = true
            untile(id)
            if let ws = workspace(showing: w) {
                let b = ws.tilingBounds
                setFrame(w, b.insetBy(dx: b.width * 0.2, dy: b.height * 0.15))
            }
        }
        layoutNow()
    }

    func toggleMinimized(_ id: CGWindowID) {
        guard let w = windows[id] else { return }
        w.element.set(kAXMinimizedAttribute, w.isMinimized ? kCFBooleanFalse : kCFBooleanTrue)
    }

    func close(_ id: CGWindowID) {
        windows[id]?.element.element(kAXCloseButtonAttribute)?.perform(kAXPressAction)
    }

    func balance() {
        workspaces.forEach { $0.tree.balance() }
        layoutNow()
    }

    /// Re-applies every frame and rediscovers windows; a cure for drift.
    func retile() {
        targetFrames.removeAll()
        observers.keys.forEach(scan)
        layoutNow()
    }

    // MARK: - Drag & drop (⌥ + left mouse)

    func isManaged(_ id: CGWindowID) -> Bool { windows[id] != nil }

    /// Where `id` would land if released at `point`; nil if nothing would change.
    func dropPlan(for id: CGWindowID, at point: CGPoint) -> DropPlan? {
        guard let ws = workspace(at: point) else { return nil }
        let others = ws.tree.windows.filter { $0 != id }
        if others.isEmpty {
            guard !ws.tree.contains(id) else { return nil }
            return DropPlan(workspace: ws, target: .emptyWorkspace, preview: ws.tilingBounds)
        }
        // Tolerate the gaps between tiles so the overlay does not flicker.
        let gap = config.gap + 1
        guard let g = ws.layout.group(at: point)
                ?? ws.layout.groups.first(where: { $0.frame.insetBy(dx: -gap, dy: -gap).contains(point) })
        else { return nil }
        let zone = Zone.at(point, in: g.frame, centerFraction: config.centerZoneFraction)
        if g.windows.contains(id), zone == .center || g.windows.count == 1 { return nil }

        let simulation = ws.tree.copy()
        simulation.drop(id, onto: g.activeWindow, zone: zone)
        let result = simulation.layout(in: ws.tilingBounds, minSizes: minSizes, options: config.layoutOptions)
        guard let preview = result.group(containing: id)?.frame else { return nil }
        return DropPlan(workspace: ws, target: .window(g.activeWindow, zone), preview: preview)
    }

    func performDrop(_ id: CGWindowID, plan: DropPlan) {
        guard let w = windows[id] else { return }
        w.isFloating = false
        for ws in workspaces where ws !== plan.workspace { ws.tree.remove(id) }
        switch plan.target {
        case .window(let target, let zone):
            plan.workspace.tree.drop(id, onto: target, zone: zone)
        case .emptyWorkspace:
            plan.workspace.tree.insert(id, near: nil, bounds: plan.workspace.tilingBounds)
        }
        targetFrames[id] = nil
        layoutNow()
        focus(id)
    }

    // MARK: - Mouse resize (⌥ + right mouse)

    private struct ResizeSession {
        let id: CGWindowID
        let edges: ResizeEdges
        let startMouse: CGPoint
        let startFrame: CGRect
        var lastApplied: TimeInterval = 0
    }

    /// Starts resizing the window at `point`; the 3×3 cell under the mouse picks the edges.
    func beginResize(_ id: CGWindowID, at point: CGPoint) -> Bool {
        guard let w = windows[id] else { return false }
        let frame = workspace(containing: id)?.layout.group(containing: id)?.windowFrame ?? w.element.frame
        guard let frame else { return false }
        resize = ResizeSession(id: id, edges: ResizeEdges.at(point, in: frame), startMouse: point, startFrame: frame)
        return true
    }

    func updateResize(to point: CGPoint, final: Bool = false) {
        guard var session = resize, let w = windows[session.id] else { return }
        // AX calls are slow; ~40 fps is plenty and keeps the event tap responsive.
        let now = ProcessInfo.processInfo.systemUptime
        guard final || now - session.lastApplied > 0.025 else { return }
        session.lastApplied = now
        resize = session

        let delta = CGVector(dx: point.x - session.startMouse.x, dy: point.y - session.startMouse.y)
        let desired = session.edges.apply(to: session.startFrame, delta: delta)
        if let ws = workspace(containing: session.id), let current = ws.layout.group(containing: session.id)?.windowFrame {
            ws.tree.applyManualResize(of: session.id, from: current, to: desired, bounds: ws.tilingBounds,
                                      minSizes: minSizes, options: config.layoutOptions)
            layoutNow()
        } else {
            setFrame(w, desired)
        }
    }

    func endResize(at point: CGPoint) {
        updateResize(to: point, final: true)
        resize = nil
    }

    // MARK: - UI

    func setNeedsUI() {
        guard !uiScheduled else { return }
        uiScheduled = true
        DispatchQueue.main.async { [weak self] in self?.refreshUI() }
    }

    private func refreshUI() {
        uiScheduled = false
        var tabStrips: [TabStrip] = []
        for ws in workspaces {
            for g in ws.layout.groups {
                guard let bar = g.tabBarFrame else { continue }
                let tabs = g.windows.compactMap { id in windows[id].map { TabStrip.Tab(window: $0, isActive: id == g.activeWindow) } }
                tabStrips.append(TabStrip(frame: bar, tabs: tabs, hasFocus: g.windows.contains { $0 == focusedID }))
            }
        }
        tabBars.show(tabStrips)
        sidebars.update(sidebarContent())
    }

    private func sidebarContent() -> [CGDirectDisplayID: SidebarContent] {
        var content: [CGDirectDisplayID: SidebarContent] = [:]
        for ws in workspaces {
            let groups = ws.layout.groups.map { g in
                SidebarGroup(items: g.windows.compactMap { id in
                    windows[id].map { item($0, isActiveTab: id == g.activeWindow) }
                })
            }
            content[ws.displayID] = SidebarContent(tiled: groups, other: [])
        }
        let untiled = windows.values
            .filter { workspace(containing: $0.id) == nil }
            .sorted { ($0.appName, $0.id) < ($1.appName, $1.id) }
        for w in untiled {
            guard let ws = workspace(showing: w) else { continue }
            content[ws.displayID]?.other.append(item(w, isActiveTab: true))
        }
        return content
    }

    private func item(_ w: ManagedWindow, isActiveTab: Bool) -> SidebarItem {
        SidebarItem(id: w.id, title: w.displayTitle, appName: w.appName, icon: w.icon,
                    isFocused: w.id == focusedID, isActiveTab: isActiveTab,
                    isFloating: w.isFloating, isMinimized: w.isMinimized || hiddenApps.contains(w.pid))
    }

    /// Hit test for the event tap: the tab under `point`, if any.
    func tab(at point: CGPoint) -> CGWindowID? { tabBars.window(at: point) }
}

private extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

private extension CGPoint {
    var rounded: CGPoint { CGPoint(x: x.rounded(), y: y.rounded()) }
}
