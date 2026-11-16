import AppKit
import SwiftUI

/// Borderless, non-activating panel used for all of mypetil's on-screen chrome.
/// Clicking it never steals focus from the app the user is working in.
final class ChromePanel: NSPanel {
    init(level: NSWindow.Level, clickThrough: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        self.level = level
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = false
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = clickThrough
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Positions the panel using AX coordinates.
    func setAXFrame(_ rect: CGRect) {
        let target = Screens.toCocoa(rect)
        if frame != target { setFrame(target, display: true) }
    }
}

/// Hosting view that reacts to the first click even though its window is never key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
