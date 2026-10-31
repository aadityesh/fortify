import AppKit

/// The lock itself: keeps every locked app hidden until it's unlocked, whatever
/// else is going on (a card up or not, notifications missed, apps already
/// running when Fortify starts, "Lock All", relocking).
///
/// Checks four times a second and immediately when asked. An app that
/// refuses to hide (some apps reject it while busy, in full screen or while
/// starting up) gets its visible windows covered until it does hide. A locked
/// app in full screen on the current Space is covered rather than hidden, since
/// hiding it makes macOS jump to another Space. Covers sit only over the locked
/// app's windows and a click on one asks for the PIN, so they never trap the user.
///
/// Opening a locked app also puts up the shield over every display before
/// anything else happens, so the app is never seen while it's hidden or covered
/// and the card comes up. It stays while the card is up.
///
/// The shield is on every Space, but macOS doesn't draw such windows on a Space
/// that's sliding in or out. So each full-screen window of a locked app also
/// gets a cover that lives on its own Space: placed (transparent) while the
/// user is there, made opaque whenever the app is locked. Sliding to or from
/// that Space then shows the cover, never the app.
@MainActor
final class LockGuard {
    /// Every locked bundle ID; running apps among these are tracked.
    var lockedIDs: () -> Set<String> = { [] }
    /// The locked apps that must be hidden right now (enforced, not unlocked).
    var guardedIDs: () -> Set<String> = { [] }
    /// A guarded app is frontmost or its cover was clicked: the user wants it.
    var onAttempt: (NSRunningApplication) -> Void = { _ in }

    private var timer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    /// When each guarded app was first seen with a window on screen.
    private var visibleSince: [pid_t: Date] = [:]
    /// Apps whose hide refusal has been logged, so it isn't logged every tick.
    private var refusalLogged: Set<pid_t> = []
    private var hidesInFlight: Set<pid_t> = []
    private var covers: [CGWindowID: (window: CoverWindow, pid: pid_t)] = [:]
    /// Full-screen apps the user just opened, on their way to their own Space.
    private var arriving: [pid_t: Date] = [:]
    /// Apps whose covers WindowServer didn't draw; they're hidden instead.
    private var coverFailed: Set<pid_t> = []
    private var coverNotDrawnSince: [CGWindowID: Date] = [:]
    private var lastSpaceChange = Date.distantPast
    private var isTicking = false
    /// No PIN request from the guard for these apps until then (just dismissed).
    private var quietUntil: [pid_t: Date] = [:]

    private let shield = LockShield()
    /// Covers bound to a full-screen window's own Space, by that window.
    private var spaceCovers: [CGWindowID: (window: CoverWindow, pid: pid_t)] = [:]
    private var lastSpaceCoverCheck = Date.distantPast
    /// The app the shield is up for.
    private var shieldTarget: pid_t?
    /// When the shield was put up, or when its card closed.
    private var shieldHeldAt = Date.distantPast
    private var shieldCardClosed = false

    func start() {
        shield.onClick = { [weak self] in
            guard let self, let pid = self.shieldTarget,
                  let app = NSRunningApplication(processIdentifier: pid) else { return }
            self.onAttempt(app)
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Lets macOS batch the wake-ups with others; notifications are the fast path.
        timer.tolerance = 0.025
        // .common: keep guarding while a menu is open or a window is dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Windows on the new Space are what matters now; recheck straight away.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastSpaceChange = Date()
                self?.tick()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        launchObserver = workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.track(app) }
        }
        terminateObserver = workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self?.tracked[pid] = nil
                self?.bundleIDs[pid] = nil
            }
        }
        rescan()
        tick()
    }

    /// Hides the app now rather than on the next tick.
    func enforce(_ app: NSRunningApplication) {
        hide(app)
    }

    /// The user is opening this locked app: cover every display now, before
    /// macOS has finished showing it and before the card is built. Called first
    /// thing on activation, unhide and launch.
    func raiseShield(for app: NSRunningApplication) {
        // Still launching: not yet seen by the tracking, which would let the shield go.
        track(app)
        shieldTarget = app.processIdentifier
        shieldHeldAt = Date()
        shieldCardClosed = false
        shield.show(for: app)
    }

    /// The app whose card is up.
    private(set) var cardTarget: pid_t?

    /// A card is opening for this app. It isn't hidden straight away: the next
    /// ticks see where its window lands. In full screen it's covered on its own
    /// Space (no jumps, no empty Space); a normal window is hidden. If it's in
    /// full screen, macOS is about to switch to its Space, so its full-screen
    /// windows are covered ahead of time.
    func cardOpened(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        cardTarget = pid
        if !coverFailed.contains(pid) {
            let fullScreen = Self.fullScreenWindows(of: pid)
            if !fullScreen.isEmpty {
                arriving[pid] = Date()
                for window in fullScreen { cover(window, of: app) }
            }
        }
        tick()
        // Catch windows as they appear (a launch, a restore from the Dock, a
        // Space switch) sooner than the regular tick would.
        for delay in [0.05, 0.12, 0.25, 0.4, 0.6, 0.9, 1.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.cardTarget == pid else { return }
                self?.tick()
            }
        }
    }

    /// The card closed without unlocking (Esc, or the user went elsewhere).
    /// Hide the app now, even in full screen: leaving its Space is wanted here,
    /// and a hidden app shows nothing in Mission Control.
    func cardClosed(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        if cardTarget == pid { cardTarget = nil }
        arriving[pid] = nil
        quietUntil[pid] = Date().addingTimeInterval(2)
        // The shield stays until the app is off screen, then comes down.
        if shieldTarget == pid {
            shieldHeldAt = Date()
            shieldCardClosed = true
        }
        hide(app)
        tick()
        for delay in [0.05, 0.12, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.tick() }
        }
    }

    /// The lock shortcut, pressed in this (just relocked) app. Every display is
    /// covered at once, since hiding can take a moment or be refused, and the
    /// app is put away as when its card is: the shield comes down as soon as
    /// it's off screen, and it isn't asked for straight back while still in front.
    func lockNow(_ app: NSRunningApplication) {
        raiseShield(for: app)
        cardClosed(for: app)
    }

    /// The app was unlocked; its covers come off at once.
    func cardUnlocked(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        if cardTarget == pid { cardTarget = nil }
        arriving[pid] = nil
        tick()
    }

    func tick() {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        // Unlocked ones too: their full-screen Spaces get covers ahead of time.
        let (guarded, unlocked) = runningApps(guarding: guardedIDs())

        // Check what's actually on screen rather than trusting "hidden": an app
        // can be reported hidden while its windows stay up because it ignored
        // the request. One window-list read covers every locked app (~0.3ms).
        let watched = Set((guarded + unlocked).map(\.processIdentifier))
        let windows = watched.isEmpty ? [:] : Self.visibleWindows(of: watched)
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let screenSizes = NSScreen.screens.map(\.frame.size)
        var covered = Set<CGWindowID>()
        var visiblePIDs = Set<pid_t>()
        let now = Date()
        for app in guarded {
            let pid = app.processIdentifier
            let list = windows[pid] ?? []
            let isArriving = arriving[pid].map { now.timeIntervalSince($0) < LockPolicy.arrivalGrace } ?? false
            if !isArriving { arriving[pid] = nil }
            if !list.isEmpty {
                visiblePIDs.insert(pid)
                if visibleSince[pid] == nil { visibleSince[pid] = now }
            }
            let decision = LockPolicy.guardDecision(
                isGuarded: true,
                isHidden: app.isHidden,
                hasVisibleWindows: !list.isEmpty,
                visibleFor: now.timeIntervalSince(visibleSince[pid] ?? now),
                isCardTarget: pid == cardTarget,
                fullScreenOnActiveSpace: list.contains { Self.isFullScreen($0.bounds, screenSizes) },
                coverFailed: coverFailed.contains(pid)
            )
            if decision.hide { hide(app) }
            if decision.cover {
                for window in list {
                    cover(window, of: app)
                    covered.insert(window.id)
                    if LockPolicy.coverShowsDrawing(width: window.bounds.width, height: window.bounds.height) {
                        checkCoverDrawn(window.id, of: app)
                    }
                }
            }
            // Keep the covers put up for an app still on its way to its Space.
            if isArriving && !coverFailed.contains(pid) {
                for (id, entry) in covers where entry.pid == pid { covered.insert(id) }
            }
            let quiet = quietUntil[pid].map { now < $0 } ?? false
            // The card target already has its card. Others are reported after the
            // tick: asking for a card opens one, which runs a tick, which must not
            // recurse back into here (that overflowed the stack).
            if pid == frontPID, pid != cardTarget, !quiet, !list.isEmpty || !app.isHidden {
                // A notification was missed: cover it now, the card follows.
                raiseShield(for: app)
                DispatchQueue.main.async { [weak self] in self?.onAttempt(app) }
            }
        }

        let guardedPIDs = Set(guarded.map(\.processIdentifier))
        visibleSince = visibleSince.filter { visiblePIDs.contains($0.key) }
        refusalLogged.formIntersection(guardedPIDs)
        // Unlocked, quit or off screen: start afresh next time.
        coverFailed.formIntersection(visiblePIDs)
        arriving = arriving.filter { guardedPIDs.contains($0.key) }
        if let target = cardTarget, !guardedPIDs.contains(target) { cardTarget = nil }
        quietUntil = quietUntil.filter { now < $0.value }
        if let target = shieldTarget, !LockPolicy.keepShield(
            targetGuarded: guardedPIDs.contains(target),
            cardUp: cardTarget == target,
            cardClosed: shieldCardClosed,
            // The window list can keep listing a full-screen window after macOS
            // has left its Space; a finished Space switch settles it.
            targetExposed: visiblePIDs.contains(target) && lastSpaceChange < shieldHeldAt,
            secondsSinceHeld: now.timeIntervalSince(shieldHeldAt)
        ) {
            shieldTarget = nil
            shield.hide()
        }
        for (id, entry) in covers where !covered.contains(id) {
            entry.window.orderOut(nil)
            covers[id] = nil
            coverNotDrawnSince[id] = nil
        }
        updateSpaceCovers(windows: windows, apps: guarded + unlocked, guardedPIDs: guardedPIDs, screenSizes: screenSizes)
    }

    /// Places a cover on the Space of every full-screen window of a locked app
    /// the user is looking at (a window is placed on the Space that's showing),
    /// and keeps each one opaque exactly while its app is locked.
    private func updateSpaceCovers(
        windows: [pid_t: [VisibleWindow]],
        apps: [NSRunningApplication],
        guardedPIDs: Set<pid_t>,
        screenSizes: [CGSize]
    ) {
        // Right after a Space switch the window list can still describe the old Space.
        let settled = Date().timeIntervalSince(lastSpaceChange) >= 0.4
        for app in apps where settled {
            let pid = app.processIdentifier
            for window in windows[pid] ?? [] where Self.isFullScreen(window.bounds, screenSizes) && spaceCovers[window.id] == nil {
                let cover = CoverWindow(frame: Self.appKitFrame(window.bounds), app: app, spaceBound: true) { [weak self] in
                    self?.onAttempt(app)
                }
                cover.setArmed(guardedPIDs.contains(pid))
                cover.orderFrontRegardless()
                spaceCovers[window.id] = (cover, pid)
            }
        }
        guard !spaceCovers.isEmpty else { return }
        for (_, entry) in spaceCovers { entry.window.setArmed(guardedPIDs.contains(entry.pid)) }
        // Drop covers whose window left full screen or closed, or whose app quit.
        // Their Spaces aren't showing, so look at every window, once a second.
        guard Date().timeIntervalSince(lastSpaceCoverCheck) >= 1 else { return }
        lastSpaceCoverCheck = Date()
        let alive = Self.fullScreenWindowIDs(of: Set(spaceCovers.values.map(\.pid)), screenSizes)
        for (id, entry) in spaceCovers where !alive.contains(id) {
            entry.window.orderOut(nil)
            spaceCovers[id] = nil
        }
    }

    /// If WindowServer doesn't draw a cover (as it once failed to draw the card on
    /// a full-screen Space), stop relying on covers for that app and hide it.
    private func checkCoverDrawn(_ id: CGWindowID, of app: NSRunningApplication) {
        guard let cover = covers[id]?.window else { return }
        // Nothing is reliably drawn while macOS animates a Space switch. Under
        // the shield a cover is hidden by design; the shield is what's drawn.
        if cover.occlusionState.contains(.visible) || shield.isDrawn
            || Date().timeIntervalSince(lastSpaceChange) < LockPolicy.spaceSwitchSettle {
            coverNotDrawnSince[id] = nil
            return
        }
        let since = coverNotDrawnSince[id] ?? Date()
        coverNotDrawnSince[id] = since
        guard Date().timeIntervalSince(since) >= LockPolicy.coverMustDrawWithin else { return }
        let pid = app.processIdentifier
        guard coverFailed.insert(pid).inserted else { return }
        lockLog.error("Cover over \(app.bundleIdentifier ?? "?", privacy: .public) isn't being drawn (frame=\(NSStringFromRect(cover.frame), privacy: .public) visible=\(cover.isVisible) occlusion=\(cover.occlusionState.rawValue)); hiding the app instead")
        arriving[pid] = nil
        hide(app)
    }

    // MARK: - Tracking running locked apps

    /// Running locked apps by process. Every property read on an
    /// NSRunningApplication can be a round trip to another process, so the
    /// guard never walks all running apps on each tick: it follows launches
    /// and quits, and rescans every second in case one was missed.
    private var tracked: [pid_t: (app: NSRunningApplication, id: String)] = [:]
    private var trackedLockedIDs: Set<String> = []
    private var lastRescan = Date.distantPast
    private static let rescanInterval: TimeInterval = 1
    /// Bundle ID of every running process seen by a rescan. Reading
    /// `bundleIdentifier` for each of the few hundred processes was most of the
    /// guard's idle CPU; a process keeps its ID, so it's read once per process.
    /// Cleared on quit, and dropped once a pid is no longer running.
    private var bundleIDs: [pid_t: String?] = [:]

    func rescan() {
        let ids = lockedIDs()
        let me = ProcessInfo.processInfo.processIdentifier
        var found: [pid_t: (app: NSRunningApplication, id: String)] = [:]
        if !ids.isEmpty {
            var seen: [pid_t: String?] = [:]
            for app in NSWorkspace.shared.runningApplications {
                let pid = app.processIdentifier
                let id = bundleIDs[pid] ?? app.bundleIdentifier
                seen[pid] = id
                guard let id, ids.contains(id), pid != me else { continue }
                found[pid] = (app, id)
            }
            bundleIDs = seen
        }
        tracked = found
        trackedLockedIDs = ids
        lastRescan = Date()
    }

    private func track(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, trackedLockedIDs.contains(id),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        tracked[app.processIdentifier] = (app, id)
    }

    /// Running locked apps, split into the ones that must stay hidden and the
    /// unlocked rest, in one pass so each app is asked `isTerminated` once.
    private func runningApps(guarding ids: Set<String>) -> (guarded: [NSRunningApplication], unlocked: [NSRunningApplication]) {
        // The lock list changed (an app was locked) or it's time for the safety rescan.
        if lockedIDs() != trackedLockedIDs || Date().timeIntervalSince(lastRescan) >= Self.rescanInterval {
            rescan()
        }
        var guarded: [NSRunningApplication] = []
        var unlocked: [NSRunningApplication] = []
        for (pid, entry) in tracked {
            if entry.app.isTerminated {
                tracked[pid] = nil
            } else if ids.contains(entry.id) {
                guarded.append(entry.app)
            } else {
                unlocked.append(entry.app)
            }
        }
        return (guarded, unlocked)
    }

    /// Off the main thread: hiding waits on the target app, and a slow or
    /// hung app must never delay the card or the next tick.
    private func hide(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard hidesInFlight.insert(pid).inserted else { return }
        let logFailure = !refusalLogged.contains(pid)
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let hidden = AppHider.hide(app, logFailure: logFailure)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hidesInFlight.remove(pid)
                    if hidden { self.refusalLogged.remove(pid) } else { self.refusalLogged.insert(pid) }
                }
            }
        }
    }

    // MARK: - Covers

    private func cover(_ window: VisibleWindow, of app: NSRunningApplication) {
        let frame = Self.appKitFrame(window.bounds)
        if let existing = covers[window.id]?.window {
            if existing.frame != frame { existing.setFrame(frame, display: true) }
            existing.orderFrontRegardless()
            return
        }
        lockLog.notice("Covering a window of \(app.bundleIdentifier ?? "?", privacy: .public)")
        let cover = CoverWindow(frame: frame, app: app) { [weak self] in
            self?.onAttempt(app)
        }
        cover.orderFrontRegardless()
        covers[window.id] = (cover, app.processIdentifier)
    }

    struct VisibleWindow {
        let id: CGWindowID
        let bounds: CGRect
    }

    /// Whether the app shows a normal window on the current Space.
    static func hasWindowOnScreen(pid: pid_t) -> Bool {
        !(visibleWindows(of: [pid])[pid] ?? []).isEmpty
    }

    /// Normal windows of these apps on the current Space, from one window-list read.
    private static func visibleWindows(of pids: Set<pid_t>) -> [pid_t: [VisibleWindow]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var result: [pid_t: [VisibleWindow]] = [:]
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 40, bounds.height > 40 else { continue }
            result[pid, default: []].append(VisibleWindow(id: number, bounds: bounds))
        }
        return result
    }

    /// A native full-screen window fills a whole display.
    private static func isFullScreen(_ bounds: CGRect, _ screenSizes: [CGSize]) -> Bool {
        screenSizes.contains { abs(bounds.width - $0.width) <= 2 && abs(bounds.height - $0.height) <= 2 }
    }

    /// Full-screen windows of these apps on any Space.
    private static func fullScreenWindowIDs(of pids: Set<pid_t>, _ sizes: [CGSize]) -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var ids = Set<CGWindowID>()
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  isFullScreen(bounds, sizes) else { continue }
            ids.insert(number)
        }
        return ids
    }

    /// The app's full-screen windows on any Space.
    private static func fullScreenWindows(of pid: pid_t) -> [VisibleWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let sizes = NSScreen.screens.map(\.frame.size)
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  isFullScreen(bounds, sizes) else { return nil }
            return VisibleWindow(id: number, bounds: bounds)
        }
    }

    /// Window-list bounds are top-left based on the primary display; AppKit's are bottom-left.
    private static func appKitFrame(_ bounds: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? bounds.maxY
        return NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}

/// An opaque panel over one window of a locked app that won't hide.
private final class CoverWindow: NSPanel {
    private let onClick: () -> Void

    /// `spaceBound`: stays on the Space it's first shown on (a full-screen
    /// app's own Space) instead of following the user to every Space.
    init(frame: NSRect, app: NSRunningApplication, spaceBound: Bool = false, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = true
        backgroundColor = ShieldView.background
        hasShadow = false
        // Above normal windows, below the lock card.
        level = .floating
        collectionBehavior = spaceBound
            ? [.fullScreenAuxiliary, .ignoresCycle]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        if spaceBound || NSScreen.screens.contains(where: { $0.frame.size == frame.size }) {
            // Seen while sliding to or from a full-screen Space, next to the shield: same look.
            let view = ShieldView()
            view.update(name: app.localizedName ?? "", icon: app.icon)
            view.onClick = onClick
            contentView = view
        } else {
            contentView = CoverView(app: app)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Opaque and clickable while the app is locked. Otherwise fully see-through
    /// and click-through, and not opaque, so the app under it isn't treated as
    /// hidden (which would pause its drawing).
    func setArmed(_ armed: Bool) {
        guard armed != (alphaValue > 0) || ignoresMouseEvents == armed else { return }
        isOpaque = armed
        alphaValue = armed ? 1 : 0
        ignoresMouseEvents = !armed
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    fileprivate func clicked() { onClick() }
}

private final class CoverView: NSView {
    init(app: NSRunningApplication) {
        super.init(frame: .zero)
        let icon = NSImageView(image: app.icon ?? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)!)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "\(app.localizedName ?? "This app") is locked · click to unlock")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = ShieldView.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Fortify isn't active when a cover is clicked; the first click must count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        (window as? CoverWindow)?.clicked()
    }
}
