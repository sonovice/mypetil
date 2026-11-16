import Carbon.HIToolbox
import MypetilCore

/// Global keyboard shortcuts via Carbon's RegisterEventHotKey (no extra permission needed).
@MainActor
final class Hotkeys {
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// ⌃⌥ is the default modifier: plain ⌥+letter types special characters on many layouts
    /// (⌥L is "@" on a German keyboard).
    static let mod = UInt32(controlKey | optionKey)
    static let modShift = UInt32(controlKey | optionKey | shiftKey)

    func installDefaults(for wm: WindowManager) {
        let dirs: [(Int, Direction)] = [(kVK_ANSI_H, .left), (kVK_ANSI_J, .down), (kVK_ANSI_K, .up), (kVK_ANSI_L, .right)]
        for (key, dir) in dirs {
            register(key, Self.mod) { wm.focusNeighbor(dir) }
            register(key, Self.modShift) { wm.swapWithNeighbor(dir) }
        }
        register(kVK_Tab, Self.mod) { wm.cycleTab(by: 1) }
        register(kVK_Tab, Self.modShift) { wm.cycleTab(by: -1) }
        register(kVK_ANSI_E, Self.mod) { wm.toggleSplitAxis() }
        register(kVK_ANSI_F, Self.mod) { wm.toggleFloating() }
        register(kVK_ANSI_B, Self.mod) { wm.balance() }
        register(kVK_ANSI_R, Self.mod) { wm.retile() }
    }

    func register(_ keyCode: Int, _ modifiers: UInt32, _ action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x6D_70_74_6C), id: id) // 'mptl'
        guard RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else {
            NSLog("mypetil: could not register hotkey \(keyCode) — already taken by another app?")
            return
        }
        refs.append(ref)
        actions[id] = action
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

private func hotkeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { hotkeys.fire(hotKeyID.id) }
    return noErr
}
