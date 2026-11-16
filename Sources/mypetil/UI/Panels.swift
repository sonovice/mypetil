import AppKit
import SwiftUI

/// Borderless, non-activating panel used for all of mypetil's on-screen chrome.
/// Clicking it never steals focus from the app the user is working in.
final class ChromePanel: NSPanel {
    init(level: NSWindow.Level, clickThrough: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        // Not `isFloatingPanel`: it would silently raise the level to .floating, putting focus
        // border and tab strips above floating windows.
        self.level = level
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = false
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = clickThrough
        animationBehavior = .none
        // No .fullScreenAuxiliary: chrome must stay out of native full-screen spaces.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the panel directly above another app's window, so windows in front of that one
    /// (floating windows, dialogs) stay in front of the panel too.
    func order(above window: CGWindowID) {
        order(.above, relativeTo: Int(window))
    }

    /// Shows the panel directly below another app's window.
    func order(below window: CGWindowID) {
        order(.below, relativeTo: Int(window))
    }

    /// Positions the panel using AX coordinates.
    func setAXFrame(_ rect: CGRect, animated: Bool = false) {
        let target = Screens.toCocoa(rect)
        guard frame != target else { return }
        // Always through the animator: an immediate move (duration 0) also replaces an
        // animation still in flight, which a plain setFrame would not.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.12 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
        }
    }
}

/// Hosting view that reacts to the first click even though its window is never key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
