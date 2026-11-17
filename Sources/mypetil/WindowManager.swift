import AppKit
import MypetilCore

/// Owns all state: known windows, one layout tree per display, and the UI that mirrors it.
///
/// Everything runs on the main thread: AX observers and the event tap deliver on the
/// main run loop.
@MainActor
final class WindowManager {
    let store: ConfigStore
    var config: Config { store.config }

    private(set) var windows: [CGWindowID: ManagedWindow] = [:]
    /// Every workspace seen so far: one per Space and display. Inactive ones keep their layout.
    private var allWorkspaces: [WorkspaceKey: Workspace] = [:]
    /// Desktop numbers as Mission Control shows them, refreshed with the workspaces.
    private var spaceNumbers: [Spaces.ID: Int] = [:]
    /// The workspaces currently on screen, one per display.
    private(set) var workspaces: [Workspace] = []
    private(set) var focusedID: CGWindowID?

    private var observers: [pid_t: AppObserver] = [:]
    private var hiddenApps: Set<pid_t> = []
    /// Windows in native full screen; they live in their own Space, outside our layout.
    private var fullScreen: Set<CGWindowID> = []
    /// Learned minimum sizes: windows that refused to become smaller than this.
    private var minSizes: [CGWindowID: CGSize] = [:]

    // Placement bookkeeping.
    /// The frame the layout last asked for (or the parking spot of a hidden tab).
    private var targetFrames: [CGWindowID: CGRect] = [:]
    /// The frame we expect the window to have now: the target, or a deviation we accepted
    /// (fixed-size window centred in its tile, learned minimum).
    private var expectedFrames: [CGWindowID: CGRect] = [:]
    /// Placements not yet confirmed. Many apps (Chromium, Electron, …) apply AX frame
    /// changes asynchronously, so we check back a moment later instead of reading back at once.
    private var unverified: [CGWindowID: Int] = [:]
    private var parkedTabs: Set<CGWindowID> = []

    // Reacting to frame changes we did not cause.
    private var touchedByUser: Set<CGWindowID> = []
    private var settleWork: [CGWindowID: DispatchWorkItem] = [:]
    private var isMouseDown = false
    private var lastMouseUp: TimeInterval = 0

    /// While the windows that already exist are being discovered: they are not tiled one by
    /// one but arranged as a whole from where they are (see `inferLayouts`).
    private var isStarting = false

    private var layoutScheduled = false
    private var uiScheduled = false
    private var verifyScheduled = false
    private var gesture: Gesture?
    /// A floating window dragged by its title bar; the event tap drives its border.
    private var nativeDrag: CGWindowID?

    private let overlays = OverlayController()
    private let focusBorder = FocusBorder()
    private let tabBars = TabBarController()
    let sidebars = SidebarController()

    /// The configuration the current state was built with, to diff against changes.
    private var appliedConfig: Config

    init(store: ConfigStore) {
        self.store = store
        self.appliedConfig = store.config
    }

    // MARK: - Lifecycle

    func start(openSettings: @escaping () -> Void) {
        AppObserver.sink = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        sidebars.actions = SidebarActions(
            focus: { [weak self] in self?.focus($0) },
            toggleFloating: { [weak self] in self?.toggleFloating($0) },
            toggleZoom: { [weak self] in self?.toggleZoom($0) },
            minimize: { [weak self] in self?.toggleMinimized($0) },
            close: { [weak self] in self?.close($0) },
            openSettings: openSettings,
            resize: { [weak self] width, final in self?.resizeSidebar(to: width, final: final) }
        )
        store.onChange = { [weak self] new in self?.apply(config: new) }
        overlays.cornerRadius = config.windowCornerRadius
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
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceChanged() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWorkspaces() }
        }

        isStarting = true
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        isStarting = false
        inferLayouts()
        if let front = NSWorkspace.shared.frontmostApplication { updateFocus(front.processIdentifier) }
        layoutNow()
        discoverWindowsOnOtherDesktops()
    }

    /// Brings parked tabs back on screen so nothing is lost when mypetil quits. They land on
    /// their tab's frame, so the next start recognises the tab group again.
    func restoreParkedWindows() {
        for ws in allWorkspaces.values {
            for g in ws.layout.groups {
                for id in g.windows where parkedTabs.contains(id) {
                    if let w = windows[id] { setFrame(w, g.windowFrame) }
                }
            }
        }
        parkedTabs.removeAll()
    }

    private func apply(config new: Config) {
        // Apps added to / removed from the floating list change their windows right away.
        let oldConfig = appliedConfig
        appliedConfig = new
        overlays.cornerRadius = new.windowCornerRadius
        for w in windows.values {
            guard let bundle = w.bundleID else { continue }
            let was = oldConfig.floatingApps.contains(bundle), now = new.floatingApps.contains(bundle)
            if was != now { setFloating(w, now) }
        }
        rebuildWorkspaces()
    }


    // MARK: - Arranging existing windows

    /// Turns the current arrangement of the windows found at start into layout trees, one per
    /// workspace, so a restart of mypetil keeps windows where they are as far as possible.
    private func inferLayouts() {
        let zOrder = Self.windowZOrder()
        var byWorkspace: [ObjectIdentifier: (ws: Workspace, windows: [ManagedWindow])] = [:]
        for w in windows.values where isTileable(w) && workspace(containing: w.id) == nil {
            guard let ws = homeWorkspace(of: w) else { continue }
            byWorkspace[ObjectIdentifier(ws), default: (ws, [])].windows.append(w)
        }
        for (ws, found) in byWorkspace.values {
            let frontToBack = found.sorted { (zOrder[$0.id] ?? .max, $0.id) < (zOrder[$1.id] ?? .max, $1.id) }
            guard ws.tree.isEmpty else {
                // A layout exists already: the newcomers join it.
                frontToBack.forEach(tile)
                continue
            }
            let frames = frontToBack.map { w in (id: w.id, frame: w.element.frame ?? ws.tilingBounds) }
            ws.tree.rebuild(from: frames, in: ws.tilingBounds, options: config.layoutOptions)
        }
        setNeedsLayout()
    }

    /// Windows on other desktops are invisible to `kAXWindowsAttribute`, so at start they would
    /// be missing from the sidebar until their desktop is visited. They are found in the
    /// background and arranged from where they are, like the windows on screen.
    private func discoverWindowsOnOtherDesktops() {
        let visibleSpaces = Set(workspaces.map(\.key.spaceID))
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var wanted: [pid_t: Set<CGWindowID>] = [:]
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID, windows[id] == nil,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, observers[pid] != nil,
                  let space = Spaces.space(of: id), !visibleSpaces.contains(space) else { continue }
            wanted[pid, default: []].insert(id)
        }
        guard !wanted.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = wanted.map { pid, ids in (pid, RemoteWindows.find(ids, of: pid)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.adoptWindowsOnOtherDesktops(found) }
            }
        }
    }

    private func adoptWindowsOnOtherDesktops(_ found: [(pid_t, [CGWindowID: AXUIElement])]) {
        isStarting = true
        for (pid, elements) in found where observers[pid] != nil {
            for (id, element) in elements where windows[id] == nil { adopt(element, id: id, pid: pid) }
        }
        isStarting = false
        inferLayouts()
    }

    /// Position of every on-screen window in the window stack, front-most first.
    private static func windowZOrder() -> [CGWindowID: Int] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (i, info) in list.enumerated() {
            if let id = info[kCGWindowNumber as String] as? CGWindowID { order[id] = i }
        }
        return order
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
        // Windows on other Spaces are missing from the list but still exist.
        let vanished = windows.values.filter { $0.pid == pid && !seen.contains($0.id) && !Spaces.windowExists($0.id) }
        vanished.map(\.id).forEach(forget)
        if !vanished.isEmpty { setNeedsLayout() }
    }

    private func adopt(_ element: AXUIElement, id: CGWindowID, pid: pid_t) {
        guard element.string(kAXRoleAttribute) == kAXWindowRole,
              element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole else { return }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let floating = !element.isSettable(kAXSizeAttribute) || config.floatingApps.contains(bundleID)
        let w = ManagedWindow(id: id, element: element, pid: pid, isFloating: floating)
        windows[id] = w
        observers[pid]?.watch(element, id: id)
        if element.bool(AXAttr.fullScreen) == true { fullScreen.insert(id) }
        if isTileable(w), !isStarting { tile(w) }
        // The focus notification of a new window often arrives before we know the window.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { updateFocus(pid) }
        setNeedsUI()
    }

    private func forget(_ id: CGWindowID) {
        guard let w = windows.removeValue(forKey: id) else { return }
        untileQuietly(id)
        observers[w.pid]?.unwatch(id)
        minSizes[id] = nil
        fullScreen.remove(id)
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
        !w.isFloating && !w.isMinimized && !hiddenApps.contains(w.pid) && !fullScreen.contains(w.id)
    }

    func workspace(containing id: CGWindowID) -> Workspace? {
        workspaces.first { $0.tree.contains(id) } ?? allWorkspaces.values.first { $0.tree.contains(id) }
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

    /// The workspace a window belongs to by its Space (and the display that Space is on).
    private func homeWorkspace(of w: ManagedWindow) -> Workspace? {
        let visible = workspace(showing: w)
        guard let space = Spaces.space(of: w.id),
              let display = Spaces.displayID(of: space, in: Spaces.displays())
                ?? visible?.displayID ?? workspaces.first?.displayID
        else { return visible }
        if let active = workspaces.first(where: { $0.key.spaceID == space && $0.displayID == display }) { return active }
        return workspace(for: WorkspaceKey(displayID: display, spaceID: space))
    }

    private func workspace(for key: WorkspaceKey) -> Workspace {
        if let ws = allWorkspaces[key] { return ws }
        let ws = Workspace(key: key)
        ws.spaceNumber = spaceNumbers[key.spaceID] ?? 0
        if let screen = NSScreen.screens.first(where: { $0.displayID == key.displayID }) {
            ws.update(screen: screen, config: config)
        }
        allWorkspaces[key] = ws
        return ws
    }

    /// Adds a window to the tree of its Space, splitting the focused tile (or the largest one).
    private func tile(_ w: ManagedWindow) {
        guard let ws = homeWorkspace(of: w) ?? focusedWorkspace else { return }
        let near = focusedID.flatMap { ws.tree.contains($0) ? $0 : nil }
        ws.tree.insert(w.id, near: near, bounds: ws.tilingBounds, minSizes: minSizes, options: config.layoutOptions)
        setNeedsLayout()
    }

    /// Removes a window from the tree. Its frame is left alone.
    private func untileQuietly(_ id: CGWindowID) {
        if let ws = workspace(containing: id) {
            ws.tree.remove(id)
            if ws.zoomed == id { ws.zoomed = nil }
        }
        targetFrames[id] = nil
        expectedFrames[id] = nil
        unverified[id] = nil
        parkedTabs.remove(id)
        setNeedsLayout()
    }

    private func setFloating(_ w: ManagedWindow, _ floating: Bool) {
        guard w.isFloating != floating else { return }
        w.isFloating = floating
        if floating {
            let ws = workspace(showing: w)
            untileQuietly(w.id)
            if let ws {
                // Float in the middle of the display, comfortably sized.
                let b = ws.tilingBounds
                let size = CGSize(width: max(b.width * 0.6, min(minSizes[w.id]?.width ?? 0, b.width)),
                                  height: max(b.height * 0.7, min(minSizes[w.id]?.height ?? 0, b.height)))
                setFrame(w, CGRect(x: b.midX - size.width / 2, y: b.midY - size.height / 2,
                                   width: size.width, height: size.height).rounded)
                w.element.perform(kAXRaiseAction)
            }
        } else if isTileable(w) {
            tile(w)
        }
        setNeedsLayout()
    }

    /// Picks the workspace of each display's current Space and refreshes all geometry.
    private func rebuildWorkspaces() {
        let spaceDisplays = Spaces.displays()
        var numbers: [Spaces.ID: Int] = [:]
        var fullScreenSpaces: Set<Spaces.ID> = []
        for d in spaceDisplays {
            for s in d.spaces {
                numbers[s.id] = s.number
                if s.isFullScreen { fullScreenSpaces.insert(s.id) }
            }
        }
        spaceNumbers = numbers

        let screens = NSScreen.screens
        workspaces = screens.map { screen in
            let current = Spaces.display(for: screen, in: spaceDisplays)?.current ?? 0
            return workspace(for: WorkspaceKey(displayID: screen.displayID, spaceID: current))
        }
        for ws in allWorkspaces.values {
            ws.spaceNumber = numbers[ws.key.spaceID] ?? 0
            if let screen = screens.first(where: { $0.displayID == ws.displayID }) {
                ws.update(screen: screen, config: config)
            }
        }
        // Workspaces of disconnected displays or deleted Spaces hand their windows over.
        let liveDisplays = Set(screens.map(\.displayID))
        for (key, orphan) in allWorkspaces where !liveDisplays.contains(key.displayID)
            || (numbers[key.spaceID] == nil && key.spaceID != 0) {
            allWorkspaces[key] = nil
            for id in orphan.tree.windows {
                if let w = windows[id], let home = homeWorkspace(of: w) ?? workspaces.first {
                    home.tree.insert(id, near: nil, bounds: home.tilingBounds, minSizes: minSizes,
                                     options: config.layoutOptions)
                }
            }
        }
        targetFrames.removeAll()
        // A native full-screen space belongs to its window alone: no sidebar there.
        sidebars.sync(workspaces.filter { !fullScreenSpaces.contains($0.key.spaceID) }, width: config.sidebarWidth, cornerRadius: config.windowCornerRadius,
                      color: config.sidebarColor.flatMap(NSColor.init(hex:)))
        setNeedsLayout()
    }

    /// Switching desktops: show that desktop's layout, adopt windows we have not seen yet
    /// and move windows that were sent to another desktop (Mission Control) to its tree.
    private func activeSpaceChanged() {
        rebuildWorkspaces()
        observers.keys.forEach(scan)
        for ws in allWorkspaces.values {
            for id in ws.tree.windows {
                guard let space = Spaces.space(of: id), space != ws.key.spaceID, let w = windows[id] else { continue }
                ws.tree.remove(id)
                if ws.zoomed == id { ws.zoomed = nil }
                parkedTabs.remove(id)
                if isTileable(w) { tile(w) }
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication { updateFocus(front.processIdentifier) }
        layoutNow()
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

    private func apply(_ ws: Workspace) {
        if let z = ws.zoomed, !ws.tree.isActiveTab(z) { ws.zoomed = nil }
        ws.layout = ws.tree.layout(in: ws.tilingBounds, minSizes: minSizes, options: config.layoutOptions)
        for g in ws.layout.groups {
            for (i, id) in g.windows.enumerated() {
                guard let w = windows[id] else { continue }
                if i != g.activeIndex {
                    park(w, on: ws)
                } else if id == ws.zoomed {
                    place(w, in: ws.tilingBounds)
                } else {
                    place(w, in: g.windowFrame)
                }
            }
        }
    }

    /// Moves a window into its tile; the result is checked a moment later (see `verify`).
    private func place(_ w: ManagedWindow, in frame: CGRect) {
        if targetFrames[w.id] == frame, !parkedTabs.contains(w.id) { return }
        parkedTabs.remove(w.id)
        targetFrames[w.id] = frame
        expectedFrames[w.id] = frame
        unverified[w.id] = 0
        setFrame(w, frame)
        scheduleVerify()
    }

    private func scheduleVerify() {
        guard !verifyScheduled else { return }
        verifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.verify() }
    }

    /// Checks placed windows. A window that is not where we put it gets a second try;
    /// if it still differs, a larger size becomes its learned minimum and a smaller one
    /// (fixed-size windows, character-cell terminals) is centred in its tile.
    private func verify() {
        verifyScheduled = false
        var relayout = false
        for (id, attempts) in unverified {
            guard let w = windows[id], let target = targetFrames[id], !parkedTabs.contains(id),
                  let actual = w.element.frame else {
                unverified[id] = nil
                continue
            }
            if actual.isClose(to: target) {
                unverified[id] = nil
                continue
            }
            if attempts < 2 {
                unverified[id] = attempts + 1
                setFrame(w, target)
                continue
            }
            unverified[id] = nil
            if let ws = workspace(containing: id),
               learnMinimum(id, requested: target.size, actual: actual.size, limit: ws.tilingBounds.size) {
                relayout = true
            }
            var accepted = actual
            if actual.width < target.width - 20 || actual.height < target.height - 20 {
                accepted.origin = CGPoint(x: target.midX - actual.width / 2, y: target.midY - actual.height / 2).rounded
                w.element.setPosition(accepted.origin)
            }
            expectedFrames[id] = accepted
        }
        if !unverified.isEmpty { scheduleVerify() }
        if relayout {
            targetFrames.removeAll()
            layoutNow()
        }
    }

    private func learnMinimum(_ id: CGWindowID, requested: CGSize, actual: CGSize, limit: CGSize) -> Bool {
        var m = minSizes[id] ?? .zero
        var changed = false
        // Never learn more than the display offers; such a value can only be a misreading.
        let width = min(actual.width, limit.width), height = min(actual.height, limit.height)
        if width > requested.width + 2, width > m.width { m.width = width; changed = true }
        if height > requested.height + 2, height > m.height { m.height = height; changed = true }
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
        unverified[w.id] = nil
        targetFrames[w.id] = CGRect(origin: origin, size: size)
        expectedFrames[w.id] = w.element.frame ?? targetFrames[w.id]
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
        case .appShown(let pid):
            hiddenApps.remove(pid)
            windows.values.filter { $0.pid == pid && isTileable($0) }.forEach(tile)
        case .destroyed(let id):
            forget(id)
        case .moved(let id), .resized(let id):
            frameChanged(id)
        case .minimized(let id):
            windows[id]?.isMinimized = true
            untileQuietly(id)
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

    private func updateFocus(_ pid: pid_t) {
        guard let app = observers[pid]?.app,
              let id = app.element(kAXFocusedWindowAttribute)?.windowID,
              windows[id] != nil else { return }
        focusedID = id
        if let ws = workspace(containing: id) {
            // Focusing a parked tab (e.g. via Cmd-Tab) makes it the visible one.
            if ws.tree.activate(id) { setNeedsLayout() }
            // Focusing another tile ends a maximized window's turn.
            if let z = ws.zoomed, z != id {
                ws.zoomed = nil
                setNeedsLayout()
            }
        }
        setNeedsUI()
    }

    /// The window that has keyboard focus right now, asked fresh from macOS.
    private var currentlyFocusedWindow: CGWindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let id = AXUIElement.application(pid).element(kAXFocusedWindowAttribute)?.windowID,
              windows[id] != nil else { return focusedID }
        return id
    }

    /// Called by the event tap for every left button transition, including ones it passes on.
    func noteMouse(down: Bool) {
        isMouseDown = down
        if !down { lastMouseUp = ProcessInfo.processInfo.systemUptime }
    }

    /// Whether a frame change right now was most likely caused by the user's mouse
    /// (dragging an edge, double-clicking the title bar). Some apps report the final
    /// frame only after the button went up, hence the grace period.
    private var mouseRecentlyActive: Bool {
        isMouseDown || ProcessInfo.processInfo.systemUptime - lastMouseUp < 0.5
    }

    /// A window moved or resized. Wait until the user lets go, then react.
    private func frameChanged(_ id: CGWindowID) {
        guard let w = windows[id] else { return }
        if syncFullScreen(w) {
            updateFocusBorder()
            return
        }
        if id == focusedID { updateFocusBorder() }
        guard gesture == nil else { return }
        guard workspace(containing: id) != nil, unverified[id] == nil,
              let expected = expectedFrames[id], let actual = w.element.frame,
              !actual.isClose(to: expected) else { return }
        if mouseRecentlyActive { touchedByUser.insert(id) }
        scheduleSettle(id)
    }

    private func scheduleSettle(_ id: CGWindowID) {
        settleWork.removeValue(forKey: id)?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle(id) }
        settleWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func settle(_ id: CGWindowID) {
        settleWork[id] = nil
        if isMouseDown {
            touchedByUser.insert(id)
            scheduleSettle(id)
            return
        }
        let byUser = touchedByUser.remove(id) != nil
        guard let ws = workspace(containing: id), let w = windows[id], let expected = expectedFrames[id],
              let actual = w.element.frame, !actual.isClose(to: expected), !parkedTabs.contains(id) else { return }

        let center = CGPoint(x: actual.midX, y: actual.midY)
        if byUser, let destination = workspace(at: center), destination !== ws {
            // Dragged onto another display: tile it there.
            moveByTitleBar(w, from: ws, to: destination)
            return
        }
        if ws.zoomed == id {
            // The user un-maximized (or otherwise changed) the maximized window.
            ws.zoomed = nil
        } else if looksMaximized(actual, on: ws) {
            // Title-bar double-click / ⌥-click on the green button.
            ws.zoomed = id
            w.element.perform(kAXRaiseAction)
        } else if byUser, let tile = ws.layout.group(containing: id)?.windowFrame {
            // Dragged an edge: the split boundaries follow, neighbours adapt.
            ws.tree.applyManualResize(of: id, from: tile, to: actual, bounds: ws.tilingBounds,
                                      minSizes: minSizes, options: config.layoutOptions)
        } else {
            // The app moved/resized itself: put it back and verify (may learn a minimum).
            unverified[id] = 0
        }
        // Anything else (e.g. dragged by the title bar) snaps back into its tile.
        targetFrames.removeAll()
        layoutNow()
    }

    /// A window dragged by its title bar onto another display joins that display's layout,
    /// landing where the mouse let go of it (split or tab, as with ⌥-drag).
    private func moveByTitleBar(_ w: ManagedWindow, from source: Workspace, to destination: Workspace) {
        let mouse = Screens.mouseLocation
        if destination.screenFrame.contains(mouse), let plan = dropPlan(for: w.id, at: mouse),
           plan.workspace === destination {
            performDrop(w.id, plan: plan)
            return
        }
        source.tree.remove(w.id)
        destination.zoomed = nil
        let near = destination.layout.group(at: mouse)?.activeWindow
        destination.tree.insert(w.id, near: near, bounds: destination.tilingBounds, minSizes: minSizes,
                                options: config.layoutOptions)
        targetFrames.removeAll()
        layoutNow()
        focus(w.id)
    }

    private func looksMaximized(_ frame: CGRect, on ws: Workspace) -> Bool {
        frame.width >= ws.tilingBounds.width * 0.97 && frame.height >= ws.tilingBounds.height * 0.97
            && (ws.layout.groups.count > 1 || ws.tree.tabs(of: ws.layout.groups.first?.activeWindow ?? 0).count > 1)
    }

    /// Takes windows out of the layout while in native full screen. Returns true if handled.
    private func syncFullScreen(_ w: ManagedWindow) -> Bool {
        let isFull = w.element.bool(AXAttr.fullScreen) == true
        if isFull, !fullScreen.contains(w.id) {
            fullScreen.insert(w.id)
            untileQuietly(w.id)
            return true
        }
        if !isFull, fullScreen.remove(w.id) != nil {
            if isTileable(w) { tile(w) }
            return true
        }
        return isFull
    }

    // MARK: - Commands

    func focus(_ id: CGWindowID) {
        guard let w = windows[id] else { return }
        if w.isMinimized { w.element.set(kAXMinimizedAttribute, kCFBooleanFalse) }
        if hiddenApps.contains(w.pid) { w.app?.unhide() }
        if let ws = workspace(containing: id) {
            var changed = ws.tree.activate(id)
            if let z = ws.zoomed, z != id { ws.zoomed = nil; changed = true }
            if changed { layoutNow() }
        }
        w.element.set(kAXMainAttribute, kCFBooleanTrue)
        w.element.perform(kAXRaiseAction)
        (observers[w.pid]?.app ?? .application(w.pid)).set(kAXFrontmostAttribute, kCFBooleanTrue)
        focusedID = id
        setNeedsUI()
    }

    /// Floats a tiled window or tiles a floating one (the focused window by default).
    func toggleFloating(_ id: CGWindowID? = nil) {
        guard let id = id ?? currentlyFocusedWindow, let w = windows[id] else {
            NSSound.beep()
            return
        }
        setFloating(w, !w.isFloating)
        layoutNow()
    }

    /// Maximizes a tiled window over its tiling area, or restores it (the focused window by default).
    func toggleZoom(_ id: CGWindowID? = nil) {
        guard let id = id ?? currentlyFocusedWindow, let ws = workspace(containing: id) else {
            NSSound.beep()
            return
        }
        ws.zoomed = ws.zoomed == id ? nil : id
        ws.tree.activate(id)
        targetFrames.removeAll()
        layoutNow()
        focus(id)
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
        targetFrames.removeAll()
        layoutNow()
    }

    /// Re-applies every frame and rediscovers windows; a cure for drift.
    func retile() {
        minSizes.removeAll()
        targetFrames.removeAll()
        observers.keys.forEach(scan)
        layoutNow()
    }

    private func resizeSidebar(to width: CGFloat, final: Bool) {
        let clamped = min(max(width, Config.sidebarWidthRange.lowerBound), Config.sidebarWidthRange.upperBound)
        if final {
            store.config.sidebarWidth = clamped.rounded()
        } else {
            sidebars.preview(width: clamped)
        }
    }

    // MARK: - Mouse gestures

    private enum Gesture {
        case move(MoveSession)
        case resize(ResizeSession)
    }

    private struct MoveSession {
        let id: CGWindowID
        let startMouse: CGPoint
        /// What the focus border framed when the drag began (tile incl. tab strip, or the window).
        let startFrame: CGRect
        var plan: DropPlan?
    }

    private struct ResizeSession {
        let id: CGWindowID
        let edges: ResizeEdges
        let startMouse: CGPoint
        let startFrame: CGRect
        let workspace: Workspace?
        var desired: CGRect
    }

    func isManaged(_ id: CGWindowID) -> Bool { windows[id] != nil }

    /// Starts dragging `id` (⌥ + left mouse, or a tab pulled out of its strip) grabbed at `point`.
    /// The window itself stays put; the focus border travels with the mouse and snaps onto
    /// the landing spot, and windows that would change size show their new frame.
    func beginMove(_ id: CGWindowID, at point: CGPoint, windowFrame: CGRect? = nil) {
        guard let w = windows[id], let frame = borderFrame(of: w, actual: windowFrame) else { return }
        gesture = .move(MoveSession(id: id, startMouse: point, startFrame: frame))
        overlays.show(moveOverlays(id, plan: nil))
        updateMove(at: point)
    }

    func updateMove(at point: CGPoint) {
        guard case .move(var session) = gesture else { return }
        let plan = dropPlan(for: session.id, at: point)
        let planChanged = plan != session.plan
        session.plan = plan
        gesture = .move(session)
        let border = plan?.preview ?? session.startFrame.offsetBy(dx: point.x - session.startMouse.x,
                                                                  dy: point.y - session.startMouse.y)
        focusBorder.show(around: border, width: config.focusBorderWidth,
                         windowCornerRadius: config.windowCornerRadius, animated: planChanged)
        if planChanged { overlays.show(moveOverlays(session.id, plan: plan)) }
        // After the other tiles, so the ghost stays on top of them.
        // Joining a group as a tab shows the group's tabs, the new one active.
        let style: OverlayItem.Style = plan?.isTab == true ? .tabTarget : .window
        let ghost = plan?.result.group(containing: session.id).flatMap { previewItem($0, style: style) }
            ?? windows[session.id].map { previewItem($0, frame: border) }
        if let ghost {
            overlays.showGhost(OverlayItem(frame: border, style: style, tabs: ghost.tabs, activeIndex: ghost.activeIndex,
                                           tabBarHeight: ghost.tabBarHeight),
                               animated: planChanged, translucent: true)
        }
    }

    func endMove() {
        guard case .move(let session) = gesture else { return }
        cancelGesture()
        if let plan = session.plan {
            performDrop(session.id, plan: plan)
        } else {
            // Released over nothing: make sure the window is (back) in its tile.
            targetFrames[session.id] = nil
            layoutNow()
        }
    }

    // MARK: Native title-bar drags

    func isTiled(_ id: CGWindowID) -> Bool { workspace(containing: id) != nil }

    /// Where the window server shows the window right now. Unlike the app's AX frame this is
    /// current during a drag, so the tap can tell at once whether a drag moves the window.
    func frame(of id: CGWindowID) -> CGRect? {
        guard windows[id] != nil,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// The user started dragging a tiled window by its title bar, and the event tap stopped
    /// the system's drag. The window goes back to where it was and the drag continues as a
    /// mypetil move, with the same previews as ⌥-drag.
    func beginTitleBarMove(_ id: CGWindowID, grabbedAt point: CGPoint, windowFrame: CGRect) {
        guard let w = windows[id] else { return }
        settleWork.removeValue(forKey: id)?.cancel()
        touchedByUser.remove(id)
        beginMove(id, at: point, windowFrame: windowFrame)
        // AX calls wait for the app; inside the event tap's callback a slow app would get the
        // tap switched off by the system (and mouse-ups lost).
        DispatchQueue.main.async { w.element.setPosition(windowFrame.origin) }
    }

    /// The user started resizing a tiled window at its edge, and the event tap stopped the
    /// system's resize. The window gets its frame back and the resize continues as a mypetil
    /// resize of the same edges, with the same previews as ⌥-resize.
    func beginEdgeResize(_ id: CGWindowID, grabbedAt point: CGPoint, edges: ResizeEdges, windowFrame: CGRect) {
        guard let w = windows[id] else { return }
        settleWork.removeValue(forKey: id)?.cancel()
        touchedByUser.remove(id)
        _ = beginResize(id, at: point, edges: edges)
        // See `beginTitleBarMove`: no AX calls inside the event tap's callback.
        DispatchQueue.main.async { [weak self] in self?.setFrame(w, windowFrame) }
    }

    /// A floating window being dragged or resized natively: the border follows the mouse
    /// directly instead of the window's delayed frame reports.
    func followSystemDrag(_ id: CGWindowID, windowFrame: CGRect) {
        nativeDrag = id
        guard config.showFocusBorder else { return }
        focusBorder.show(around: windowFrame, width: config.focusBorderWidth,
                         windowCornerRadius: config.windowCornerRadius, below: id)
    }

    func endSystemDrag() {
        nativeDrag = nil
        updateFocusBorder()
    }

    /// Starts resizing the window at `point` (⌥ + right mouse). Only a preview is shown
    /// until the button is released.
    func beginResize(_ id: CGWindowID, at point: CGPoint, edges grabbed: ResizeEdges? = nil) -> Bool {
        guard windows[id] != nil else { return false }
        let ws = workspace(containing: id)
        if let ws, ws.zoomed == id {
            ws.zoomed = nil
            targetFrames.removeAll()
            setNeedsLayout()   // not here: this runs inside the event tap
        }
        guard let frame = ws?.layout.group(containing: id)?.windowFrame ?? self.frame(of: id) else { return false }
        // The grabbed thirds follow what the user sees, which can differ from the tile
        // (e.g. a window larger than its tile because of its minimum size).
        let edges = grabbed ?? ResizeEdges.at(point, in: self.frame(of: id) ?? frame)
        let session = ResizeSession(id: id, edges: edges, startMouse: point,
                                    startFrame: frame, workspace: ws, desired: frame)
        gesture = .resize(session)
        updateResize(at: point)
        return true
    }

    func updateResize(at point: CGPoint) {
        guard case .resize(var session) = gesture else { return }
        let delta = CGVector(dx: point.x - session.startMouse.x, dy: point.y - session.startMouse.y)
        session.desired = session.edges.apply(to: session.startFrame, delta: delta).rounded
        gesture = .resize(session)
        // Like a move: every tile previewed, the resized window's own tile with the focus border.
        let (frame, ghost, others) = resizePreview(session)
        overlays.show(others)
        if let ghost { overlays.showGhost(ghost, animated: false) }
        focusBorder.show(around: frame, width: config.focusBorderWidth, windowCornerRadius: config.windowCornerRadius)
    }

    func endResize() {
        guard case .resize(let session) = gesture else { return }
        cancelGesture()
        guard let w = windows[session.id] else { return }
        if let ws = session.workspace, ws.tree.contains(session.id) {
            ws.tree.applyManualResize(of: session.id, from: session.startFrame, to: session.desired,
                                      bounds: ws.tilingBounds, minSizes: minSizes, options: config.layoutOptions)
            layoutNow()
        } else {
            setFrame(w, session.desired)
        }
    }

    func cancelGesture() {
        gesture = nil
        overlays.hide()
        setNeedsUI()   // puts the focus border back (not right here: may run inside the event tap)
    }

    /// Where `id` would land if released at `point`; nil if nothing would change.
    private func dropPlan(for id: CGWindowID, at point: CGPoint) -> DropPlan? {
        guard let ws = workspace(at: point) else { return nil }
        let options = config.layoutOptions
        if ws.tree.windows.allSatisfy({ $0 == id }) {
            guard !ws.tree.contains(id) else { return nil }
            let sim = LayoutTree()
            sim.insert(id, near: nil, bounds: ws.tilingBounds)
            return DropPlan(workspace: ws, target: .emptyWorkspace, preview: ws.tilingBounds,
                            result: sim.layout(in: ws.tilingBounds, minSizes: minSizes, options: options))
        }
        // Tolerate the gaps between tiles so the overlay does not flicker.
        let gap = config.gap + 1
        guard let g = ws.layout.group(at: point)
                ?? ws.layout.groups.first(where: { $0.frame.insetBy(dx: -gap, dy: -gap).contains(point) })
        else { return nil }
        let zone = Zone.at(point, in: g.frame, centerFraction: config.centerZoneFraction)
        if g.windows.contains(id), zone == .center || g.windows.count == 1 { return nil }

        let sim = ws.tree.copy()
        sim.drop(id, onto: g.activeWindow, zone: zone)
        let result = sim.layout(in: ws.tilingBounds, minSizes: minSizes, options: options)
        guard let preview = result.group(containing: id)?.frame else { return nil }
        return DropPlan(workspace: ws, target: .window(g.activeWindow, zone), preview: preview, result: result)
    }

    private func performDrop(_ id: CGWindowID, plan: DropPlan) {
        guard let w = windows[id] else { return }
        w.isFloating = false
        for ws in workspaces where ws !== plan.workspace { ws.tree.remove(id) }
        plan.workspace.zoomed = nil
        switch plan.target {
        case .window(let target, let zone):
            plan.workspace.tree.drop(id, onto: target, zone: zone)
        case .emptyWorkspace:
            plan.workspace.tree.insert(id, near: nil, bounds: plan.workspace.tilingBounds)
        }
        targetFrames.removeAll()
        layoutNow()
        focus(id)
    }

    // MARK: Gesture overlays

    /// A preview tile (icon and title) for every tiled window on screen, at the frame it would
    /// have after the drop, so the whole layout reads at a glance. Before a target is found
    /// the dragged window keeps its own tile; its travelling copy is the ghost (see `updateMove`).
    private func moveOverlays(_ id: CGWindowID, plan: DropPlan?) -> [OverlayItem] {
        let sourceWS = workspace(containing: id)
        var items: [OverlayItem] = []
        for ws in workspaces {
            let layout: LayoutResult
            if let plan, ws === plan.workspace {
                layout = plan.result
            } else if plan != nil, ws === sourceWS {
                let sim = ws.tree.copy()
                sim.remove(id)
                layout = sim.layout(in: ws.tilingBounds, minSizes: minSizes, options: config.layoutOptions)
            } else {
                layout = ws.layout
            }
            items += previewTiles(layout, excluding: plan == nil ? nil : id)
        }
        // A floating window has no tile; it is previewed where it is.
        if plan == nil, sourceWS == nil, case .move(let session) = gesture, let w = windows[id] {
            items.append(previewItem(w, frame: session.startFrame))
        }
        return items
    }

    /// Where the resized window would end up, its preview tile, and preview tiles for every
    /// other tiled window.
    private func resizePreview(_ session: ResizeSession) -> (frame: CGRect, ghost: OverlayItem?, others: [OverlayItem]) {
        var frame = session.desired
        var ghost = windows[session.id].map { previewItem($0, frame: frame) }
        var items: [OverlayItem] = []
        for ws in workspaces {
            var layout = ws.layout
            if ws === session.workspace, ws.tree.contains(session.id) {
                let sim = ws.tree.copy()
                sim.applyManualResize(of: session.id, from: session.startFrame, to: session.desired,
                                      bounds: ws.tilingBounds, minSizes: minSizes, options: config.layoutOptions)
                layout = sim.layout(in: ws.tilingBounds, minSizes: minSizes, options: config.layoutOptions)
                if let g = layout.group(containing: session.id) {
                    frame = g.frame
                    ghost = previewItem(g, style: .window)
                }
            }
            items += previewTiles(layout, excluding: session.id)
        }
        return (frame, ghost, items)
    }

    /// A preview tile (icon and title) for every tile of `layout` except the one showing `id`.
    private func previewTiles(_ layout: LayoutResult, excluding id: CGWindowID?) -> [OverlayItem] {
        layout.groups.compactMap { g in g.activeWindow == id ? nil : previewItem(g, style: .window) }
    }

    /// A tile's preview, with all its tabs.
    private func previewItem(_ g: GroupLayout, style: OverlayItem.Style) -> OverlayItem? {
        let tabs = g.windows.compactMap { windows[$0].map { OverlayItem.Tab(title: $0.displayTitle, icon: $0.icon) } }
        guard !tabs.isEmpty else { return nil }
        let active = g.windows.filter { windows[$0] != nil }.firstIndex(of: g.activeWindow) ?? 0
        return OverlayItem(frame: g.frame, style: style, tabs: tabs, activeIndex: active,
                           tabBarHeight: g.tabBarFrame?.height ?? config.tabBarHeight)
    }

    /// A single window's preview.
    private func previewItem(_ w: ManagedWindow, frame: CGRect) -> OverlayItem {
        OverlayItem(frame: frame, style: .window, tabs: [.init(title: w.displayTitle, icon: w.icon)], activeIndex: 0)
    }

    // MARK: - UI

    func setNeedsUI() {
        guard !uiScheduled else { return }
        uiScheduled = true
        DispatchQueue.main.async { [weak self] in self?.refreshUI() }
    }

    private func refreshUI() {
        uiScheduled = false
        var strips: [TabStrip] = []
        for ws in workspaces {
            for g in ws.layout.groups {
                let hasFocus = g.windows.contains { $0 == focusedID }
                // A maximized window covers the tiles; their tab strips would float above it.
                guard let bar = g.tabBarFrame, ws.zoomed == nil else { continue }
                let tabs = g.windows.compactMap { id in windows[id].map { TabStrip.Tab(window: $0, isActive: id == g.activeWindow) } }
                strips.append(TabStrip(frame: bar, windowFrame: g.windowFrame, tabs: tabs, hasFocus: hasFocus,
                                       cornerRadius: config.windowCornerRadius))
            }
        }
        tabBars.show(strips)
        updateFocusBorder()
        sidebars.update(sidebarContent())
    }

    /// Draws the focus border around where the focused window actually is right now, so it
    /// follows the window while it is dragged or resized, and also frames floating windows.
    private func updateFocusBorder() {
        // During a gesture the border belongs to the preview (see `updateMove`, `updateResize`).
        if gesture != nil || nativeDrag != nil { return }
        guard config.showFocusBorder, let id = focusedID, let w = windows[id],
              !w.isMinimized, !parkedTabs.contains(id), !fullScreen.contains(id), !hiddenApps.contains(w.pid),
              isOnVisibleSpace(w), let frame = borderFrame(of: w) else {
            focusBorder.hide()
            return
        }
        focusBorder.show(around: frame, width: config.focusBorderWidth, windowCornerRadius: config.windowCornerRadius,
                         below: id)
    }

    /// The window's actual frame; a window resting in its tile shares the border with its tab strip.
    private func borderFrame(of w: ManagedWindow, actual known: CGRect? = nil) -> CGRect? {
        guard let actual = known ?? w.element.frame else { return nil }
        if let ws = workspace(containing: w.id), ws.zoomed != w.id, let g = ws.layout.group(containing: w.id),
           g.tabBarFrame != nil, actual.isClose(to: g.windowFrame, tolerance: 4) {
            return g.frame
        }
        return actual
    }

    private func isOnVisibleSpace(_ w: ManagedWindow) -> Bool {
        if let ws = workspace(containing: w.id) { return workspaces.contains { $0 === ws } }
        guard let space = Spaces.space(of: w.id) else { return true }
        return workspaces.contains { $0.key.spaceID == space }
    }

    private func sidebarContent() -> [CGDirectDisplayID: SidebarContent] {
        var content: [CGDirectDisplayID: SidebarContent] = [:]
        for ws in workspaces {
            let groups = ws.layout.groups.map { g in
                SidebarGroup(items: g.windows.compactMap { id in
                    windows[id].map { item($0, isActiveTab: id == g.activeWindow, isZoomed: ws.zoomed == id) }
                })
            }
            content[ws.displayID] = SidebarContent(tiled: groups, other: [])
        }
        // Other desktops of each display, so their windows stay reachable.
        for ws in allWorkspaces.values.sorted(by: { $0.spaceNumber < $1.spaceNumber })
        where !ws.tree.isEmpty && !workspaces.contains(where: { $0 === ws }) {
            let items = ws.tree.windows.compactMap { id in
                windows[id].map { item($0, isActiveTab: ws.tree.isActiveTab(id), isZoomed: ws.zoomed == id) }
            }
            let title = ws.spaceNumber > 0 ? "Desktop \(ws.spaceNumber)" : "Anderer Desktop"
            content[ws.displayID]?.otherSpaces.append(SpaceSection(id: ws.key.spaceID, title: title, items: items))
        }
        let untiled = windows.values
            .filter { workspace(containing: $0.id) == nil }
            .sorted { ($0.appName, $0.id) < ($1.appName, $1.id) }
        for w in untiled {
            // Floating windows of other desktops are not visible here.
            if let space = Spaces.space(of: w.id), !w.isMinimized, !fullScreen.contains(w.id),
               !workspaces.contains(where: { $0.key.spaceID == space }) { continue }
            guard let ws = workspace(showing: w) else { continue }
            content[ws.displayID]?.other.append(item(w, isActiveTab: true, isZoomed: false))
        }
        return content
    }

    private func item(_ w: ManagedWindow, isActiveTab: Bool, isZoomed: Bool) -> SidebarItem {
        SidebarItem(id: w.id, title: w.displayTitle, appName: w.appName, icon: w.icon,
                    isFocused: w.id == focusedID, isActiveTab: isActiveTab, isFloating: w.isFloating,
                    isZoomed: isZoomed, isMinimized: w.isMinimized || hiddenApps.contains(w.pid),
                    isFullScreen: fullScreen.contains(w.id))
    }

    /// Hit test for the event tap: the tab under `point`, if any.
    func tab(at point: CGPoint) -> TabHit? { tabBars.hit(at: point) }
}

private extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    var rounded: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}

private extension CGPoint {
    var rounded: CGPoint { CGPoint(x: x.rounded(), y: y.rounded()) }
}
