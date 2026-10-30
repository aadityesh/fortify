import AppKit
import ApplicationServices
import os

let lockLog = Logger(subsystem: "com.aadi.applock", category: "lock")

/// Hides and shows other apps. With the Accessibility permission this goes through
/// the AX "hidden" attribute, which macOS always honors. Without it, it falls back to
/// `NSRunningApplication.hide()`, which macOS 14+ often ignores for a background caller.
enum AppHider {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt (once) and returns the current state.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Clears AppLock's Accessibility entry and asks again. Fixes the case where
    /// the switch in System Settings is on but belongs to an older build with a
    /// different signature, so macOS doesn't apply it to this one.
    static func resetAccessibility() {
        let tccutil = Process()
        tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.aadi.applock"]
        do {
            try tccutil.run()
            tccutil.waitUntilExit()
            lockLog.notice("tccutil reset Accessibility exited with \(tccutil.terminationStatus)")
        } catch {
            lockLog.error("tccutil reset failed: \(error.localizedDescription, privacy: .public)")
        }
        requestAccessibility()
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// `logFailure: false` keeps a retry loop from logging the same refusal over and over.
    @discardableResult
    static func hide(_ app: NSRunningApplication, logFailure: Bool = true) -> Bool {
        if hasAccessibility, setHidden(true, app, logFailure: logFailure) { return true }
        let ok = app.hide()
        if !ok, logFailure {
            lockLog.error("hide() refused for \(app.bundleIdentifier ?? "?", privacy: .public); accessibility=\(hasAccessibility)")
        }
        return ok
    }

    /// Makes AppLock the active app. macOS 14+ often ignores `NSApp.activate()` from
    /// a background app; with Accessibility we can set ourselves frontmost directly.
    /// Touch ID's inline glyph only works (isn't greyed out) while AppLock is active.
    static func activateSelf() {
        unhideSelf()
        NSApp.activate()
        guard hasAccessibility else { return }
        let me = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let error = AXUIElementSetAttributeValue(me, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if error != .success {
            lockLog.error("AX frontmost failed: \(error.rawValue)")
        }
    }

    /// Brings another app to the front. Like `activateSelf`, a background
    /// caller's `activate()` is often ignored, so with Accessibility it's also
    /// set frontmost directly. Waits on that app; call it off the main thread.
    static func activate(_ app: NSRunningApplication) {
        app.activate(options: [])
        guard hasAccessibility else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        let error = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if error != .success {
            lockLog.error("AX frontmost failed for \(app.bundleIdentifier ?? "?", privacy: .public): \(error.rawValue)")
        }
    }

    /// If every window of the app is minimized, brings the first one back.
    static func restoreMinimizedWindow(_ app: NSRunningApplication) {
        guard hasAccessibility else { return }
        let windows = PresenceWatcher.axWindows(of: app.processIdentifier)
        guard !windows.isEmpty, windows.allSatisfy(PresenceWatcher.isMinimized), let window = windows.first else { return }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        lockLog.notice("Restored a minimized window of \(app.bundleIdentifier ?? "?", privacy: .public) after unlock")
    }

    /// A hidden app draws none of its windows. `NSApp.unhide` can be refused for a
    /// background app, so also clear AX "hidden" on our own process.
    static func unhideSelf() {
        guard NSApp.isHidden else { return }
        NSApp.unhideWithoutActivation()
        if hasAccessibility {
            _ = setHidden(false, NSRunningApplication.current)
        }
        lockLog.notice("Fortify My Mac was hidden; unhid it (still hidden=\(NSApp.isHidden))")
    }

    static func unhide(_ app: NSRunningApplication) {
        if hasAccessibility, setHidden(false, app) { return }
        app.unhide()
    }

    private static func setHidden(_ hidden: Bool, _ app: NSRunningApplication, logFailure: Bool = true) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Never wait long on an app that's hung: the default AX timeout is 6s.
        AXUIElementSetMessagingTimeout(element, 0.25)
        let error = AXUIElementSetAttributeValue(element, kAXHiddenAttribute as CFString, hidden as CFBoolean)
        if error != .success, logFailure {
            lockLog.error("AX hidden=\(hidden) failed for \(app.bundleIdentifier ?? "?", privacy: .public): \(error.rawValue)")
        }
        return error == .success
    }
}
