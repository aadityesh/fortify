import AppKit
import ApplicationServices

/// Watches unlocked apps and reports when one leaves the screen: minimized,
/// hidden, or all its windows closed. Switching between visible apps doesn't count.
/// Accessibility notifications drive it; a 1s poll backs them up because
/// Electron apps (Claude, VS Code) don't always send them.
@MainActor
final class PresenceWatcher {
    var onLeftScreen: (NSRunningApplication, String) -> Void = { _, _ in }

    private struct Watched {
        let app: NSRunningApplication
        let observer: AXObserver?
        var emptyChecks = 0
        /// Last time a window of the app was on screen.
        var lastSeen = Date.distantPast
        /// When watching began, and whether a window has been on screen since.
        var startedAt = Date()
        var hasBeenOnScreen = false
        var isWebApp = false
        /// Left the screen only because the user switched Space (e.g. away from a
        /// full-screen window). It's still open there, so it doesn't relock.
        var parkedOnOtherSpace = false
        var parkedSince: Date?
    }

    private var watched: [pid_t: Watched] = [:]
    private var pendingStarts: [pid_t: DispatchWorkItem] = [:]
    /// Apps seen on screen while their watch was starting. Without this, a
    /// window closed in those first moments looks like one not yet drawn, and
    /// the app stayed unlocked until `firstWindowGrace` ran out.
    private var seenWhileStarting: Set<pid_t> = []
    private var pollTimer: Timer?
    private var lastSpaceChange = Date.distantPast
    private var spaceObserver: NSObjectProtocol?
    var fullScreenUnlockDuration: TimeInterval = 300

    init() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
    }

    /// Apps that were on screen just before the switch are parked on the Space we
    /// left. Windows on other Spaces don't show up in AX or the on-screen list, so
    /// without this, switching away from a full-screen app, or to another desktop,
    /// would relock it as if its windows had been closed.
    private func spaceChanged() {
        lastSpaceChange = Date()
        for (pid, var entry) in watched where Date().timeIntervalSince(entry.lastSeen) < 2.5 {
            let isParked = Self.hasFullscreenWindow(pid: pid) || Self.hasWindowInWindowServer(pid: pid)
            if isParked && !entry.parkedOnOtherSpace { entry.parkedSince = Date() }
            entry.parkedOnOtherSpace = isParked
            entry.emptyChecks = 0
            watched[pid] = entry
        }
    }

    /// Starts watching after a short grace period: right after unlocking, the
    /// app is still being shown again and would look absent.
    func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        stop(app)
        let start = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.begin(app) }
        }
        pendingStarts[pid] = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: start)
        for delay in [0.3, 0.6, 0.9, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.pendingStarts[pid] != nil, Self.isOnScreen(app) else { return }
                self.seenWhileStarting.insert(pid)
            }
        }
    }

    func stop(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        pendingStarts.removeValue(forKey: pid)?.cancel()
        seenWhileStarting.remove(pid)
        if let entry = watched.removeValue(forKey: pid), let observer = entry.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        updatePolling()
    }

    func stopAll() {
        for entry in Array(watched.values) { stop(entry.app) }
        for start in pendingStarts.values { start.cancel() }
        pendingStarts.removeAll()
        seenWhileStarting.removeAll()
    }

    // MARK: - Watching

    private func begin(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        pendingStarts[pid] = nil
        guard !app.isTerminated else { return }
        var entry = Watched(app: app, observer: makeObserver(pid: pid), lastSeen: Date())
        entry.isWebApp = Self.isWebApp(app)
        entry.hasBeenOnScreen = seenWhileStarting.remove(pid) != nil
        // The watcher starts shortly after unlock so the app can restore its
        // windows. If the user switched Spaces during that startup grace, recover
        // the parked fullscreen state instead of missing the whole timer.
        if !Self.isOnScreen(app), Date().timeIntervalSince(lastSpaceChange) < 2.5,
           Self.hasFullscreenWindow(pid: pid) || Self.hasWindowInWindowServer(pid: pid) {
            entry.parkedOnOtherSpace = true
            entry.parkedSince = lastSpaceChange
        }
        watched[pid] = entry
        updatePolling()
        check(pid, reason: "initial check")
    }

    private func makeObserver(pid: pid_t) -> AXObserver? {
        var observer: AXObserver?
        guard AXObserverCreate(pid, presenceCallback, &observer) == .success, let observer else { return nil }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [
            kAXWindowMiniaturizedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXApplicationHiddenNotification,
        ] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        return observer
    }

    private func updatePolling() {
        if watched.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // One window-list read for every watched app, not one each.
                    let onScreen = Self.pidsWithOnScreenWindow()
                    for pid in Array(self.watched.keys) { self.check(pid, reason: "poll", onScreen: onScreen) }
                }
            }
            timer.tolerance = 0.1
            pollTimer = timer
        }
    }

    fileprivate func notificationArrived(pid: pid_t, name: String) {
        guard watched[pid] != nil else { return }
        // Let the app finish what it's doing (e.g. the minimize animation).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.check(pid, reason: name) }
        }
    }

    /// Relocks after two empty checks in a row, so a window that is briefly
    /// closed and reopened (or mid-animation) doesn't trigger it.
    /// `onScreen`: pids with an on-screen window, when the caller already read the list.
    private func check(_ pid: pid_t, reason: String, onScreen: Set<pid_t>? = nil) {
        guard var entry = watched[pid] else { return }
        if entry.app.isTerminated {
            stop(entry.app)
            return
        }
        let isOnScreen = onScreen.map { !entry.app.isHidden && $0.contains(pid) } ?? Self.isOnScreen(entry.app)
        if isOnScreen {
            entry.emptyChecks = 0
            entry.lastSeen = Date()
            entry.hasBeenOnScreen = true
            entry.parkedOnOtherSpace = false
            entry.parkedSince = nil
            watched[pid] = entry
            return
        }
        // Not drawn its first window yet: still starting, not closed.
        if PresencePolicy.shouldWaitForFirstWindow(
            hasBeenOnScreen: entry.hasBeenOnScreen,
            secondsSinceWatchStarted: Date().timeIntervalSince(entry.startedAt),
            isWebApp: entry.isWebApp
        ) {
            return
        }
        // Still open on another Space, or the Space animation is still running.
        // Keep the unlock while there are live windows parked on that Space, but
        // don't let that exception survive minimizing or closing those windows.
        // AX reports minimized windows even when they aren't in the window list;
        // an empty AX window list means there's nothing left to park.
        let windows = Self.axWindows(of: pid)
        let hasUnminimizedWindow = windows.contains { !Self.isMinimized($0) }
        let hasWindowServerWindow = Self.hasWindowInWindowServer(pid: pid)
        let parkedUnlockExpired = entry.parkedOnOtherSpace && entry.parkedSince.map {
            Date().timeIntervalSince($0) >= fullScreenUnlockDuration
        } ?? false
        let keepParked = PresencePolicy.shouldKeepParkedUnlock(
            isParkedOnOtherSpace: entry.parkedOnOtherSpace,
            hasAccessibilityWindows: !windows.isEmpty,
            hasUnminimizedWindow: hasUnminimizedWindow,
            hasWindowServerWindow: hasWindowServerWindow,
            withinSpaceTransitionGrace: Date().timeIntervalSince(lastSpaceChange) < 1.5,
            parkedUnlockExpired: parkedUnlockExpired
        )
        if keepParked {
            entry.emptyChecks = 0
            watched[pid] = entry
            return
        }
        // Keep the expired marker through the confirmation check so the final
        // callback can distinguish timer expiry and hide the still-open app.
        if entry.parkedOnOtherSpace && !parkedUnlockExpired {
            entry.parkedOnOtherSpace = false
            entry.parkedSince = nil
            watched[pid] = entry
        }
        entry.emptyChecks += 1
        watched[pid] = entry
        guard entry.emptyChecks >= 2 else {
            // Confirm soon rather than waiting for the next poll.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.check(pid, reason: reason) }
            }
            return
        }
        let app = entry.app
        stop(app)
        onLeftScreen(app, parkedUnlockExpired ? "full-screen grace expired" : Self.describe(app, reason: reason))
    }

    // MARK: - Presence

    /// Not hidden, and has a normal window on the currently visible Spaces.
    nonisolated static func isOnScreen(_ app: NSRunningApplication) -> Bool {
        if app.isHidden { return false }
        return hasOnScreenWindow(pid: app.processIdentifier)
    }

    nonisolated static func isWebApp(_ app: NSRunningApplication) -> Bool {
        PresencePolicy.isWebApp(
            bundleIdentifier: app.bundleIdentifier,
            executableName: app.executableURL?.lastPathComponent,
            info: app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
        )
    }

    nonisolated static func axWindows(of pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        let element = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    nonisolated static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    nonisolated private static func hasOnScreenWindow(pid: pid_t) -> Bool {
        pidsWithOnScreenWindow().contains(pid)
    }

    /// Every process with a normal window on the currently visible Spaces.
    nonisolated private static func pidsWithOnScreenWindow() -> Set<pid_t> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var pids = Set<pid_t>()
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t { pids.insert(pid) }
        }
        return pids
    }

    /// Unlike the on-screen list, optionAll can still report a normal window
    /// on a different Space. Use it to distinguish a parked window from an app
    /// whose windows were closed while it was parked.
    nonisolated private static func hasWindowInWindowServer(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }

    /// A native full-screen window occupies the complete display frame. Read all
    /// Spaces so this still works just after macOS switches away from the window.
    nonisolated static func hasFullscreenWindow(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let screenSizes = NSScreen.screens.map { $0.frame.size }
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return false }
            return screenSizes.contains {
                abs(bounds.width - $0.width) <= 2 && abs(bounds.height - $0.height) <= 2
            }
        }
    }

    private static func describe(_ app: NSRunningApplication, reason: String) -> String {
        if app.isHidden { return "hidden" }
        let windows = axWindows(of: app.processIdentifier)
        if windows.isEmpty { return "windows closed" }
        if windows.allSatisfy(isMinimized) { return "minimized" }
        return reason
    }
}

private func presenceCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let name = notification as String
    let box = UInt(bitPattern: refcon)
    // The observer's source is on the main run loop, so this runs on the main thread.
    MainActor.assumeIsolated {
        Unmanaged<PresenceWatcher>.fromOpaque(UnsafeRawPointer(bitPattern: box)!)
            .takeUnretainedValue()
            .notificationArrived(pid: pid, name: name)
    }
}
