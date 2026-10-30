import Foundation

/// Small, deterministic rules for keeping unlock sessions safe across Spaces.
enum PresencePolicy {
    static func shouldRelockAfterLeaving(relockWhenLeaving: Bool, fullscreenGraceExpired: Bool) -> Bool {
        relockWhenLeaving || fullscreenGraceExpired
    }

    /// How long a just-unlocked app may take to show its first window.
    static let firstWindowGrace: TimeInterval = 15

    /// Right after unlock, a slow-starting app (a web app, a cold launch) may not
    /// have drawn a window yet. That isn't "all windows closed", so don't relock
    /// until it has been on screen once, or the grace runs out (so an app that
    /// never shows a window doesn't stay unlocked indefinitely). Web apps always
    /// have a window, but some browsers draw it from the browser process rather
    /// than the web app's own, where it can't be seen; they wait with no limit
    /// and still relock on hide, quit (closing the window quits them), sleep,
    /// screen lock and "Lock all".
    static func shouldWaitForFirstWindow(
        hasBeenOnScreen: Bool,
        secondsSinceWatchStarted: TimeInterval,
        isWebApp: Bool = false
    ) -> Bool {
        !hasBeenOnScreen && (isWebApp || secondsSinceWatchStarted < firstWindowGrace)
    }

    /// A site installed as an app from a browser. Chromium browsers (Chrome,
    /// Edge, Brave, Opera, Vivaldi, Arc, …) install a small `app_mode_loader`
    /// stub whose Info.plist carries `CrAppModeShortcutID`; Safari's "Add to
    /// Dock" apps have bundle IDs under `com.apple.Safari.WebApp.`.
    static func isWebApp(bundleIdentifier: String?, executableName: String?, info: [String: Any]?) -> Bool {
        if info?["CrAppModeShortcutID"] != nil || executableName == "app_mode_loader" { return true }
        return bundleIdentifier?.hasPrefix("com.apple.Safari.WebApp.") == true
    }

    static func shouldKeepParkedUnlock(
        isParkedOnOtherSpace: Bool,
        hasAccessibilityWindows: Bool,
        hasUnminimizedWindow: Bool,
        hasWindowServerWindow: Bool,
        withinSpaceTransitionGrace: Bool,
        parkedUnlockExpired: Bool = false
    ) -> Bool {
        if parkedUnlockExpired { return false }
        if withinSpaceTransitionGrace { return true }
        guard isParkedOnOtherSpace else { return false }
        // Accessibility can briefly return a stale, destroyed AX window after
        // the user closes the last window. WindowServer is the source of truth
        // that a window still exists on another Space.
        return hasWindowServerWindow && (!hasAccessibilityWindows || hasUnminimizedWindow)
    }
}
