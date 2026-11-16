import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var wm: WindowManager?
    private var mouse: MouseController?
    private let hotkeys = Hotkeys()
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        installSignalHandlers()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            launch()
        } else {
            NSLog("mypetil: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)")
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                MainActor.assumeIsolated { self?.launch() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        wm?.restoreParkedWindows()
    }

    private func launch() {
        Config.writeDefaultIfMissing()
        let wm = WindowManager(config: .load())
        self.wm = wm
        wm.start()
        let mouse = MouseController(wm: wm)
        if !mouse.start() { NSLog("mypetil: could not create mouse event tap") }
        self.mouse = mouse
        hotkeys.installDefaults(for: wm)
        rebuildMenu()
    }

    // MARK: Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "mypetil")
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        if wm == nil {
            menu.addItem(withTitle: "Wartet auf Bedienungshilfen-Zugriff …", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(item("Neu anordnen  (⌃⌥R)", #selector(retile)))
            menu.addItem(item("Ausgleichen  (⌃⌥B)", #selector(balance)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Konfiguration öffnen", #selector(openConfig)))
        menu.addItem(.separator())
        menu.addItem(item("mypetil beenden", #selector(quit), key: "q"))
        statusItem?.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func retile() { wm?.retile() }
    @objc private func balance() { wm?.balance() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openConfig() {
        Config.writeDefaultIfMissing()
        NSWorkspace.shared.open(Config.fileURL)
    }

    /// Ctrl-C in the terminal must not leave parked tabs off-screen.
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
