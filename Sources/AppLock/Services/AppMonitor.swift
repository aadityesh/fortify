import AppKit

/// Decides which apps are locked right now and asks for the PIN when one is opened.
///
/// Two independent layers:
/// - `LockGuard` keeps every locked app hidden until it's unlocked. That's the lock.
///   Opening one puts up its shield over every display first, so the app is never seen.
/// - The notch card asks for the PIN when the user tries to open one. It never
///   captures input, so if it fails ⌘Tab still gets the user out.
@MainActor
final class AppMonitor {
    private let store: LockStore
    private let notch = NotchPanelController()
    private let presence = PresenceWatcher()
    private let lockGuard = LockGuard()
    private var sessionUnlocked: Set<String> = []
    /// The app the user was in before opening a locked one; Esc goes back there.
    private var previousApp: NSRunningApplication?
    /// Apps the user was in, most recent first; the lock shortcut goes back to
    /// the one before the app it locks.
    private var recentApps: [NSRunningApplication] = []
    private let lockShortcut = GlobalHotKey()
    private lazy var notifier = LockNotifier()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    /// Sleep or screen lock: AppLock's own window should lock too.
    var onSessionLocked: () -> Void = {}
    /// Just before a card appears (e.g. to put away our own window on another Space,
    /// so activating Fortify doesn't switch Spaces to it).
    var onWillPresentCard: () -> Void = {}

    init(store: LockStore) {
        self.store = store
    }

    func start() {
        store.onRelockWhenLeavingChange = { [weak self] in self?.relockPreferenceChanged() }
        presence.fullScreenUnlockDuration = store.fullScreenUnlockDuration
        store.onFullScreenUnlockDurationChange = { [weak self] duration in
            self?.presence.fullScreenUnlockDuration = duration
        }
        // Leaving the screen (minimize, ⌘H, closing every window) relocks the app.
        presence.onLeftScreen = { [weak self] app, reason in
            guard let self, let id = app.bundleIdentifier else { return }
            // The full-screen grace period is independent from the optional
            // minimize/hide/close relock preference.
            guard PresencePolicy.shouldRelockAfterLeaving(
                relockWhenLeaving: self.store.relockWhenLeaving,
                fullscreenGraceExpired: reason == "full-screen grace expired"
            ) else { return }
            guard self.sessionUnlocked.remove(id) != nil else { return }
            lockLog.notice("Relocked \(id, privacy: .public): left the screen (\(reason, privacy: .public))")
            // A process with no windows can remain frontmost; hiding it makes
            // reopening it observable (didUnhide) and the guard keeps it so.
            self.lockGuard.enforce(app)
        }

        lockGuard.lockedIDs = { [weak self] in self?.store.lockedIDs ?? [] }
        lockGuard.guardedIDs = { [weak self] in self?.mustStayHidden() ?? [] }
        lockGuard.onAttempt = { [weak self] app in self?.challenge(app, freshLaunch: false) }
        lockGuard.start()

        lockShortcut.onPress = { [weak self] in self?.lockFrontmost() }
        registerLockShortcut(store.lockShortcut)
        store.onLockShortcutChange = { [weak self] combo in self?.registerLockShortcut(combo) }
        store.onRecordingShortcut = { [weak self] recording in
            guard let self else { return }
            if recording { self.lockShortcut.unregister() } else { self.registerLockShortcut(self.store.lockShortcut) }
        }
        if let front = NSWorkspace.shared.frontmostApplication { noteRecent(front) }

        let ws = NSWorkspace.shared.notificationCenter
        // Before the app has drawn anything: cover the screen so its first
        // window never shows. The card follows once it has launched.
        observe(ws, NSWorkspace.willLaunchApplicationNotification) { [weak self] app in
            guard let self, let id = app.bundleIdentifier, self.mustStayHidden().contains(id) else { return }
            self.lockGuard.raiseShield(for: app)
        }
        observe(ws, NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            self?.challenge(app, freshLaunch: true)
        }
        observe(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            self?.challenge(app, freshLaunch: false)
            self?.notePrevious(app)
            self?.noteRecent(app)
        }
        // Selecting a full-screen Space can change the frontmost app without a
        // useful activation notification. Recheck the app on the active Space.
        observeEvent(ws, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            self?.challengeFrontmost()
        }
        // Reopening a closed-window app may unhide the existing process without
        // activating it (it can still be the frontmost process).
        observe(ws, NSWorkspace.didUnhideApplicationNotification) { [weak self] app in
            self?.challenge(app, freshLaunch: false)
        }
        observe(ws, NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            self?.appTerminated(app)
        }
        // ⌘H: relock straight away instead of waiting for the presence check.
        observe(ws, NSWorkspace.didHideApplicationNotification) { [weak self] app in
            guard let self, self.store.relockWhenLeaving, let id = app.bundleIdentifier,
                  self.sessionUnlocked.contains(id) else { return }
            self.sessionUnlocked.remove(id)
            self.presence.stop(app)
            lockLog.notice("Relocked \(id, privacy: .public): left the screen (hidden)")
        }

        // Re-lock everything when the Mac sleeps or the screen locks.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observeEvent(ws, name) { [weak self] _ in self?.sessionLocked() }
        }
        observeEvent(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in
            self?.sessionLocked()
        }
        // A locked app that was frontmost when the screen locked gets challenged again.
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observeEvent(ws, name) { [weak self] _ in self?.challengeFrontmost() }
        }
        observeEvent(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in
            self?.challengeFrontmost()
        }
    }

    /// Keep watching unlocked apps when this preference changes. Fullscreen
    /// Space timeouts still apply when ordinary leave relocking is off.
    private func relockPreferenceChanged() {
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, sessionUnlocked.contains(id) else { continue }
            presence.watch(app)
        }
    }

    private func sessionLocked() {
        sessionUnlocked.removeAll()
        presence.stopAll()
        notch.dismiss(result: .abandoned)
        lockGuard.tick()
        onSessionLocked()
    }

    /// "Lock all apps now": every locked app hides and asks again next time it's opened.
    func relockAll() {
        sessionUnlocked.removeAll()
        presence.stopAll()
        lockGuard.tick()
        challengeFrontmost()
    }

    // MARK: - Lock shortcut

    private func registerLockShortcut(_ combo: KeyCombo?) {
        store.lockShortcutRefused = !lockShortcut.register(combo)
    }

    /// The lock shortcut: the unlocked app in front locks at once, and the user
    /// is back in the app they were in before it. Anything else just beeps.
    private func lockFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              sessionUnlocked.contains(id), store.isLocked(id) else {
            NSSound.beep()
            return
        }
        sessionUnlocked.remove(id)
        presence.stop(app)
        lockLog.notice("Relocked \(id, privacy: .public): lock shortcut")
        // Chosen before hiding: macOS would otherwise pick whichever app is next.
        let guarded = mustStayHidden()
        let back = recentApps.first {
            $0.processIdentifier != app.processIdentifier && !$0.isTerminated && !$0.isHidden
                && !guarded.contains($0.bundleIdentifier ?? "")
        } ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        if let back {
            DispatchQueue.global(qos: .userInteractive).async { AppHider.activate(back) }
        }
        lockGuard.lockNow(app)
        notifier.appLocked(app)
    }

    /// Ordinary apps (Dock icon), not Fortify itself.
    private func noteRecent(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        recentApps.removeAll { $0.processIdentifier == app.processIdentifier || $0.isTerminated }
        recentApps.insert(app, at: 0)
        if recentApps.count > 8 { recentApps.removeLast() }
    }

    // MARK: - Locking

    /// Apps that are locked and not unlocked this session.
    private func mustStayHidden() -> Set<String> {
        let me = Bundle.main.bundleIdentifier
        return Set(store.lockOrder.filter { $0 != me && !sessionUnlocked.contains($0) })
    }

    private func challenge(_ app: NSRunningApplication, freshLaunch: Bool) {
        guard let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier,
              store.isLocked(id), !app.isTerminated else { return }
        if sessionUnlocked.contains(id) {
            // An unlocked app may have stopped its watcher after it was
            // minimized/closed while ordinary relocking was disabled. Restart
            // it on activation so a later fullscreen Space switch is timed.
            presence.watch(app)
            return
        }
        // First, before anything slower: macOS is showing the app right now.
        lockGuard.raiseShield(for: app)
        // macOS often reports a new app active before it reports the launch.
        let freshLaunch = freshLaunch || app.launchDate.map { Date().timeIntervalSince($0) < 5 } ?? false

        if notch.currentApp?.processIdentifier == app.processIdentifier {
            notch.refocus()
            return
        }
        // Covered where it is while the card is up, rather than hidden: hiding
        // makes macOS jump to another Space, or leaves an empty one.
        lockGuard.cardOpened(for: app)
        // The newest app the user tried to open gets the card; any other locked
        // app simply stays hidden until it's opened again.
        present(app, freshLaunch: freshLaunch)
    }

    private func present(_ app: NSRunningApplication, freshLaunch: Bool) {
        onWillPresentCard()
        let store = store
        notch.present(
            app: app,
            pinLength: store.pinLength,
            useTouchID: store.useTouchID,
            verify: { await store.verify($0) },
            setPIN: { store.setPIN($0) },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .unlocked:
                    // Unlock before showing, so the guard lets it be.
                    if let id = app.bundleIdentifier { self.sessionUnlocked.insert(id) }
                    self.lockGuard.cardUnlocked(for: app)
                    AppHider.unhide(app)
                    // Opened from the Dock while minimized: show the window, no second click.
                    AppHider.restoreMinimizedWindow(app)
                    app.activate(options: [.activateAllWindows])
                    self.showAfterUnlock(app)
                    self.presence.watch(app)
                case .cancelled:
                    // The user doesn't want it any more: a fresh launch is
                    // closed, an already-running app just stays hidden.
                    // Either way the guard lets go of the card, so the shield
                    // can't wait on an app that ignores the quit (unsaved work).
                    if freshLaunch { app.terminate() }
                    self.lockGuard.cardClosed(for: app)
                case .superseded, .abandoned:
                    // Stays hidden and locked; opening it again asks again.
                    self.lockGuard.cardClosed(for: app)
                }
            },
            dismissed: { [weak self] result in
                self?.notchDismissed(after: result)
            }
        )
    }

    /// Makes sure the unlocked app actually shows up. A closed window (the app
    /// still running) or a window on another desktop stays out of sight after
    /// activating, so reopen it as a Dock click would.
    private func showAfterUnlock(_ app: NSRunningApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + LockPolicy.reopenCheckDelay) {
            guard !app.isTerminated, let url = app.bundleURL else { return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let userMovedOn = front != app.processIdentifier && front != ProcessInfo.processInfo.processIdentifier
            guard LockPolicy.shouldReopenAfterUnlock(
                hasWindowOnScreen: LockGuard.hasWindowOnScreen(pid: app.processIdentifier),
                userMovedOn: userMovedOn
            ) else { return }
            lockLog.notice("\(app.bundleIdentifier ?? "?", privacy: .public) shows no window after unlock; reopening it")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            configuration.promptsUserIfNeeded = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    lockLog.error("Reopening after unlock failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Remembers the last ordinary app the user was in (not a locked one, not us).
    private func notePrevious(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier, !mustStayHidden().contains(id) else { return }
        previousApp = app
    }

    private func notchDismissed(after result: NotchResult) {
        // After Esc, go back to the app the user came from, unless our own window
        // is up. macOS switches to that app's Space, which also leaves a locked
        // full-screen app's Space: macOS won't hide a full-screen app, and Finder
        // (the fallback) often has no window to switch Spaces to.
        guard result == .cancelled,
              !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        let back = previousApp.flatMap { $0.isTerminated ? nil : $0 }
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        back?.activate(options: [])
        // Never NSApp.hide(nil) here: a hidden AppLock can't reliably unhide
        // itself later, and then the next card is never drawn.
    }

    private func appTerminated(_ app: NSRunningApplication) {
        if let id = app.bundleIdentifier { sessionUnlocked.remove(id) }
        presence.stop(app)
        if notch.currentApp?.processIdentifier == app.processIdentifier {
            notch.dismiss(result: .abandoned)
        }
    }

    private func challengeFrontmost() {
        if let front = NSWorkspace.shared.frontmostApplication {
            challenge(front, freshLaunch: false)
        }
    }

    // MARK: - Helpers

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        handler: @escaping (NSRunningApplication) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { handler(app) }
        }
        tokens.append((center, token))
    }

    private func observeEvent(_ center: NotificationCenter, _ name: Notification.Name, handler: @escaping (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { handler(note) }
        }
        tokens.append((center, token))
    }
}
