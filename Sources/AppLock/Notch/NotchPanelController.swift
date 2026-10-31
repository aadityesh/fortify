import AppKit
import CoreGraphics
import SwiftUI

enum NotchResult {
    case unlocked
    /// Esc or the cancel button.
    case cancelled
    /// Another locked app was opened; its card replaced this one.
    case superseded
    /// The user moved on (switched apps, the app quit, the Mac locked).
    case abandoned
}

/// Borderless panel that can sit over the menu bar and take keyboard input.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Allow placement over the menu bar / notch area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Fortify usually isn't active when the card is clicked (that click is
/// how focus comes back); the first click must reach the card, not just activate.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where the notch is and how big the lock card gets on a given screen.
struct NotchGeometry {
    let notchSize: CGSize
    let hasNotch: Bool
    let expandedSize: CGSize
    let panelFrame: NSRect

    /// Extra room around the card for the shake animation and drop shadow.
    private static let margin = CGSize(width: 40, height: 50)

    init(screen: NSScreen) {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            hasNotch = true
        } else {
            notchSize = CGSize(width: 190, height: 30)
            hasNotch = false
        }
        expandedSize = CGSize(width: max(notchSize.width + 170, 390), height: notchSize.height + 168)

        let width = expandedSize.width + Self.margin.width * 2
        let height = expandedSize.height + Self.margin.height
        panelFrame = NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
    }
}

@MainActor
@Observable
final class NotchModel {
    enum Mode: Equatable {
        case unlock
        /// Forgot PIN: the Mac password dialog is up.
        case confirmingOwner
        /// Forgot PIN: type a new PIN, then the same again.
        case newPIN, confirmNewPIN
    }

    var mode = Mode.unlock
    var expanded = false
    /// True once the expand animation has finished, so content has its final size.
    var settled = false
    var visible = false
    var appName = ""
    var icon: NSImage?
    var entered = ""
    var isVerifyingPIN = false
    var pinLength = 4
    var attempts = 0
    var message: String?
    var biometricsAvailable = false
    /// Shown instead of the Touch ID hint when it can't be used (e.g. lid closed).
    var touchIDNote: String?
    /// Shown when the card doesn't have keyboard focus. Clicking it calls `onRefocus`.
    var focusHint: String?
    var notchSize = CGSize(width: 190, height: 32)
    var hasNotch = true
    var expandedSize = CGSize(width: 390, height: 200)

    /// Drives the inline Touch ID glyph in the card.
    @ObservationIgnored let biometrics = BiometricSession()
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onRefocus: () -> Void = {}
    @ObservationIgnored var onForgotPIN: () -> Void = {}
}

/// The lock card that grows out of the notch.
///
/// It only asks for the PIN; keeping the locked app out of sight is
/// `LockGuard`'s job (its shield covers the screen while the card is up).
/// So the card never captures input outside itself: if macOS fails to draw it
/// (as happened around full-screen Space switches), ⌘Tab still works, the
/// locked app stays covered, and the card recovers by itself (see `checkVisible`).
@MainActor
final class NotchPanelController {
    private var panel: NotchPanel?
    private let model = NotchModel()
    private var biometrics: BiometricSession { model.biometrics }
    private var keyMonitor: Any?
    /// Esc×3 while the card doesn't have focus (keys go to another app).
    private var escapeMonitor: Any?
    private var escapeTaps = TripleTapDetector()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var watchdog: Timer?

    /// Bumped by every present; delayed work belonging to an older card is dropped.
    private var generation = 0
    private var verify: ((String) async -> PINVerification)?
    private var setPIN: ((String) -> Void)?
    /// Forgot PIN: the Mac password dialog. While it's up the card never takes focus.
    private let ownerCheck = OwnerCheck()
    /// Forgot PIN: set once the Mac password is confirmed.
    private var reset: PINResetFlow?
    private var completion: ((NotchResult) -> Void)?
    private var dismissed: ((NotchResult) -> Void)?
    /// The collapse animation is running.
    private var isDismissing = false

    // Focus
    private var focusRequestedAt = Date.distantPast
    private var reclaims = 0
    private var notKeySince: Date?

    // Visibility
    private var notVisibleSince: Date?
    private var lastRecovery = LockPolicy.CardRecovery.none
    private var rebuilds = 0
    private var leftFullScreenSpace = false
    private var lastSpaceChange = Date.distantPast
    private var presentedAt = Date()
    private var reportedVisible = false

    /// The assistive-tech overlay level: above app windows, the menu bar, the
    /// Dock and notch utilities such as boringNotch, so nothing covers the card.
    /// Not the shielding level: WindowServer reserves it and didn't draw the card there.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))

    private(set) var currentApp: NSRunningApplication?
    var isPresenting: Bool { currentApp != nil }

    init() {
        model.onCancel = { [weak self] in self?.dismiss(result: .cancelled) }
        model.onRefocus = { [weak self] in self?.refocus() }
        model.onForgotPIN = { [weak self] in self?.forgotPIN() }
    }

    // MARK: - Presenting

    /// Shows the card for `app`. If a card for another app is up, this one replaces it.
    func present(
        app: NSRunningApplication,
        pinLength: Int,
        useTouchID: Bool,
        verify: @escaping (String) async -> PINVerification,
        setPIN: @escaping (String) -> Void,
        completion: @escaping (NotchResult) -> Void,
        dismissed: @escaping (NotchResult) -> Void
    ) {
        let replacing = currentApp != nil
        if replacing {
            let previous = self.completion
            self.completion = nil
            self.dismissed = nil
            previous?(.superseded)
        }
        // A card that's still collapsing (or replaced) keeps its window on screen.
        let reuseWindow = (replacing || isDismissing) && panel != nil

        generation += 1
        let generation = generation
        currentApp = app
        self.verify = verify
        self.setPIN = setPIN
        self.completion = completion
        self.dismissed = dismissed
        isDismissing = false
        biometrics.cancel()
        ownerCheck.cancel()
        reset = nil
        model.mode = .unlock

        let screen = targetScreen()
        let geometry = NotchGeometry(screen: screen)
        model.appName = app.localizedName ?? "This app"
        model.icon = app.icon
        model.entered = ""
        model.isVerifyingPIN = false
        model.pinLength = pinLength
        model.message = nil
        model.focusHint = nil
        // One coreauthd round trip before the card shows, not two.
        let touchID = useTouchID ? Biometrics.status : .unsupported
        let offerTouchID = touchID.isSupported
        model.touchIDNote = offerTouchID ? Biometrics.unavailableReason(touchID) : nil
        model.biometricsAvailable = offerTouchID && model.touchIDNote == nil
        model.notchSize = geometry.notchSize
        model.hasNotch = geometry.hasNotch
        model.expandedSize = geometry.expandedSize
        model.visible = true

        lockLog.notice("Notch presenting for \(app.bundleIdentifier ?? "?", privacy: .public); active=\(NSApp.isActive) reuse=\(reuseWindow) touchID=\(self.model.biometricsAvailable) screen=\(screen.localizedName, privacy: .public)")

        presentedAt = Date()
        reportedVisible = false
        notKeySince = nil
        notVisibleSince = nil
        lastRecovery = .none
        rebuilds = 0
        leftFullScreenSpace = false

        if !reuseWindow { dropPanel() }
        let panel = makePanelIfNeeded()
        panel.setFrame(geometry.panelFrame, display: true)
        panel.orderFrontRegardless()
        requestFocus()

        installKeyMonitor()
        installObservers()
        startWatchdog()

        if reuseWindow && model.expanded {
            model.settled = true
        } else {
            model.expanded = false
            model.settled = false
            // Let the collapsed state render first so the spring has somewhere to grow from.
            DispatchQueue.main.async { [model] in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.expanded = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.generation == generation, self.currentApp != nil else { return }
                self.model.settled = true
            }
        }
        // Evaluation starts once the inline glyph is on screen (see BiometricSession).
        if model.biometricsAvailable { requestTouchID() }
    }

    /// The locked app was opened again, or the card was clicked: bring the card
    /// forward and give it keyboard focus.
    func refocus() {
        guard let panel, currentApp != nil, !isDismissing else { return }
        panel.orderFrontRegardless()
        requestFocus()
    }

    // MARK: - Focus

    /// Activates Fortify and makes the card key. Starts a short hand-off
    /// period in which focus taken by others (macOS passing it along after
    /// hiding the locked app) is taken back.
    private func requestFocus() {
        focusRequestedAt = Date()
        reclaims = 0
        takeFocus()
    }

    private func takeFocus() {
        // The Mac password dialog has the keyboard; taking it back would stop
        // the user typing their password.
        guard let panel, !ownerCheck.isRunning else { return }
        AppHider.activateSelf()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Within the hand-off period only, and a bounded number of times, so the
    /// card never fights the user or another app for focus.
    private func reclaimFocus() {
        guard currentApp != nil, !isDismissing, let panel, !(panel.isKeyWindow && NSApp.isActive) else { return }
        guard Date().timeIntervalSince(focusRequestedAt) < LockPolicy.focusHandoff, reclaims < 8 else { return }
        reclaims += 1
        takeFocus()
    }

    private func otherAppActivated(_ app: NSRunningApplication) {
        guard let current = currentApp, !isDismissing, !ownerCheck.isRunning,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let isLockedTarget = app.processIdentifier == current.processIdentifier
        switch LockPolicy.otherAppActivated(
            secondsSinceFocusRequest: Date().timeIntervalSince(focusRequestedAt),
            secondsSinceSpaceChange: Date().timeIntervalSince(lastSpaceChange),
            isLockedTarget: isLockedTarget,
            isRegularApp: app.activationPolicy == .regular
        ) {
        case .reclaim:
            if isLockedTarget { refocus() } else { reclaimFocus() }
        case .dismiss:
            lockLog.notice("\(app.bundleIdentifier ?? "?", privacy: .public) became active; putting the card away")
            dismiss(result: .abandoned)
        case .ignore:
            break
        case .recheckSoon:
            let generation = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.generation == generation, self.currentApp != nil, !self.isDismissing,
                      !self.ownerCheck.isRunning,
                      let panel = self.panel, !(panel.isKeyWindow && NSApp.isActive),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                lockLog.notice("\(app.bundleIdentifier ?? "?", privacy: .public) is still active after a Space switch; putting the card away")
                self.dismiss(result: .abandoned)
            }
        }
    }

    private func installObservers() {
        removeObservers()
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        func add(_ nc: NotificationCenter, _ name: Notification.Name, _ object: AnyObject? = nil, _ handler: @escaping @MainActor (Notification) -> Void) {
            let token = nc.addObserver(forName: name, object: object, queue: .main) { note in
                MainActor.assumeIsolated { handler(note) }
            }
            observers.append((nc, token))
        }
        add(center, NSWindow.didChangeOcclusionStateNotification, panel) { [weak self] _ in
            self?.checkVisible()
        }
        add(center, NSWindow.didResignKeyNotification, panel) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.reclaimFocus() }
        }
        add(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.otherAppActivated(app)
        }
        // A Space switch is when WindowServer has failed to draw the card:
        // order it in on the new Space once the animation is done.
        add(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            guard let self else { return }
            self.lastSpaceChange = Date()
            self.notVisibleSince = nil
            self.lastRecovery = .none
            let generation = self.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.generation == generation, self.currentApp != nil, !self.isDismissing,
                      let panel = self.panel else { return }
                panel.orderFrontRegardless()
                if Date().timeIntervalSince(self.focusRequestedAt) < LockPolicy.focusHandoff || panel.isKeyWindow {
                    self.takeFocus()
                }
            }
        }
    }

    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkVisible()
                self?.updateFocusHint()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private var cardIsVisible: Bool {
        guard let panel else { return false }
        return panel.isVisible && panel.occlusionState.contains(.visible)
    }

    /// Makes sure the card is actually drawn. AppKit's occlusion state says
    /// whether any of it is visible on the current Space (the window list's
    /// "on screen" flag claimed it was when it wasn't). Escalates through
    /// `LockPolicy.cardRecovery`; nothing here blocks the user.
    private func checkVisible() {
        guard let panel, let app = currentApp, !isDismissing else { return }
        if cardIsVisible {
            if !reportedVisible {
                reportedVisible = true
                lockLog.notice("Notch card visible after \(Int(Date().timeIntervalSince(self.presentedAt) * 1000))ms")
            }
            if notVisibleSince != nil, lastRecovery != .none {
                lockLog.notice("Notch card is visible again (after \(String(describing: self.lastRecovery), privacy: .public))")
            }
            notVisibleSince = nil
            lastRecovery = .none
            return
        }
        // A hidden Fortify draws no windows at all.
        if NSApp.isHidden {
            AppHider.unhideSelf()
            panel.orderFrontRegardless()
        }
        let since = notVisibleSince ?? Date()
        notVisibleSince = since
        let step = LockPolicy.cardRecovery(
            notVisibleFor: Date().timeIntervalSince(since),
            lastStep: lastRecovery,
            rebuilds: rebuilds
        )
        guard step != .none else { return }
        lastRecovery = step
        switch step {
        case .none:
            break
        case .reorder:
            lockLog.error("Notch card not visible; ordering it in again")
            panel.orderFrontRegardless()
            if panel.isKeyWindow || Date().timeIntervalSince(focusRequestedAt) < LockPolicy.focusHandoff { takeFocus() }
        case .leaveFullScreenSpace:
            // Only when the switch to the hidden app's full-screen Space is the
            // likely cause, never e.g. while Mission Control is open.
            guard !leftFullScreenSpace, Date().timeIntervalSince(lastSpaceChange) < 3,
                  PresenceWatcher.hasFullscreenWindow(pid: app.processIdentifier) else { return }
            leftFullScreenSpace = true
            lockLog.error("Notch card not visible on \(app.bundleIdentifier ?? "?", privacy: .public)'s full-screen Space; returning to the desktop")
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [])
            // Focus comes back once the Space switch lands (see the observer).
            focusRequestedAt = Date()
            reclaims = 0
        case .rebuild:
            rebuilds += 1
            lockLog.error("Notch card still not visible; rebuilding its window (\(self.rebuilds))")
            rebuildPanel()
            notVisibleSince = Date()
            lastRecovery = .none
        }
    }

    private func rebuildPanel() {
        dropPanel()
        let panel = makePanelIfNeeded()
        panel.setFrame(NotchGeometry(screen: targetScreen()).panelFrame, display: true)
        panel.orderFrontRegardless()
        installObservers()
        requestFocus()
        // The Touch ID view was paired with the old window; start a new request.
        if model.biometricsAvailable, model.mode == .unlock { requestTouchID() }
    }

    /// When the card can't take typing, say so; a click on it fixes that.
    private func updateFocusHint() {
        guard let panel, currentApp != nil, !isDismissing, model.settled else { return }
        let hasFocus = panel.isKeyWindow && NSApp.isActive
        if hasFocus || ownerCheck.isRunning {
            notKeySince = nil
            if model.focusHint != nil {
                withAnimation(.easeOut(duration: 0.15)) { model.focusHint = nil }
            }
            return
        }
        let since = notKeySince ?? Date()
        notKeySince = since
        guard Date().timeIntervalSince(since) >= 0.5 else { return }
        let hint = model.biometricsAvailable && model.mode == .unlock ? "Touch ID paused · click here to resume" : "Click here, then type your PIN"
        if model.focusHint != hint {
            withAnimation(.easeOut(duration: 0.15)) { model.focusHint = hint }
            lockLog.notice("Notch card lost focus to \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
        }
    }

    // MARK: - Dismissing

    /// Collapses the card back into the notch and fades it out.
    func dismiss(result: NotchResult) {
        guard currentApp != nil, !isDismissing else { return }
        lockLog.notice("Notch dismissed (\(String(describing: result), privacy: .public)) for \(self.currentApp?.bundleIdentifier ?? "?", privacy: .public)")
        isDismissing = true
        let generation = generation
        model.settled = false
        model.focusHint = nil
        biometrics.cancel()
        ownerCheck.cancel()
        reset = nil
        removeKeyMonitor()
        removeObservers()
        stopWatchdog()

        let completion = completion
        let dismissed = dismissed
        self.completion = nil
        self.dismissed = nil
        currentApp = nil
        verify = nil
        setPIN = nil
        completion?(result)

        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { model.expanded = false }
        withAnimation(.easeOut(duration: 0.18).delay(0.12)) { model.visible = false }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            // A new card took over the window in the meantime.
            guard let self, self.generation == generation else { return }
            self.isDismissing = false
            self.dropPanel()
            dismissed?(result)
        }
    }

    // MARK: - Auth

    private func requestTouchID() {
        guard currentApp != nil, !isDismissing, model.mode == .unlock else { return }
        let generation = generation
        biometrics.begin(reason: "unlock \(model.appName)") { [weak self] result in
            guard let self, self.generation == generation, self.currentApp != nil, !self.isDismissing else { return }
            switch result {
            case .success:
                self.dismiss(result: .unlocked)
            case .noMatch, .failed, .cancelled:
                self.model.message = "Touch ID didn't work. Type your PIN"
            case .interrupted:
                break
            }
        }
    }

    /// Forgot PIN: the Mac password (or Touch ID) proves it's the owner; then a
    /// new PIN is typed twice right on the card, and the app opens.
    private func forgotPIN() {
        guard let app = currentApp, !isDismissing, model.mode == .unlock, !ownerCheck.isRunning else { return }
        let generation = generation
        biometrics.cancel()
        model.entered = ""
        model.message = nil
        model.focusHint = nil
        model.mode = .confirmingOwner
        lockLog.notice("Forgot PIN on the card for \(app.bundleIdentifier ?? "?", privacy: .public); asking for the Mac password")
        ownerCheck.begin(reason: "reset your Fortify PIN") { [weak self] result in
            guard let self, self.generation == generation, self.currentApp != nil, !self.isDismissing else { return }
            switch result {
            case .success:
                self.reset = PINResetFlow()
                self.model.mode = .newPIN
                lockLog.notice("Mac password confirmed; choosing a new PIN on the card")
            case .noMatch, .failed:
                self.model.mode = .unlock
                self.model.message = "Couldn't confirm your Mac password"
            case .cancelled, .interrupted:
                self.model.mode = .unlock
            }
            // The dialog had the keyboard; the card takes it back for typing.
            self.panel?.orderFrontRegardless()
            self.requestFocus()
            if self.model.mode == .unlock, self.model.biometricsAvailable { self.requestTouchID() }
        }
    }

    /// A full new PIN was typed while resetting.
    private func submitNewPIN() {
        // Return with a short PIN does nothing; the new PIN keeps the same length.
        guard var flow = reset, currentApp != nil, !isDismissing, model.entered.count == model.pinLength else { return }
        let entered = model.entered
        let outcome = flow.submit(entered)
        reset = flow
        model.entered = ""
        switch outcome {
        case .confirmNext:
            model.message = nil
            model.mode = .confirmNewPIN
        case .mismatch:
            model.mode = .newPIN
            model.message = "Those didn't match · type a new PIN"
            withAnimation(.linear(duration: 0.4)) { model.attempts += 1 }
        case .done(let pin):
            setPIN?(pin)
            lockLog.notice("PIN reset with the Mac password (lock card)")
            dismiss(result: .unlocked)
        }
    }

    private func submit() async {
        if reset != nil {
            submitNewPIN()
            return
        }
        let generation = generation
        guard let verify, currentApp != nil, !isDismissing, !model.entered.isEmpty, !model.isVerifyingPIN else { return }
        let entered = model.entered
        model.isVerifyingPIN = true
        let result = await verify(entered)
        guard self.generation == generation, currentApp != nil, !isDismissing else { return }
        model.isVerifyingPIN = false
        switch result {
        case .accepted:
            dismiss(result: .unlocked)
        case .rejected:
            model.entered = ""
            model.message = "Wrong PIN, try again"
            withAnimation(.linear(duration: 0.4)) { model.attempts += 1 }
        case .lockedOut(let seconds):
            model.entered = ""
            model.message = "Too many attempts · wait \(seconds)s"
        }
    }

    // MARK: - Keyboard

    /// Keys reach the card only while it's the key window, like any other
    /// window: nothing is intercepted system-wide.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let keyCode = event.keyCode
            let characters = event.charactersIgnoringModifiers
            let window = event.window
            // Only a Bool crosses the actor boundary; NSEvent isn't Sendable.
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let panel = self.panel, window === panel else { return false }
                self.handleKey(keyCode: keyCode, characters: characters)
                // Swallow everything aimed at the card, including ⌘H / ⌘Q / ⌘W.
                return true
            }
            return consumed ? nil : event
        }
        // Without focus the card can't see Esc, which leaves the user looking at
        // the shield. Esc pressed three times quickly anywhere backs out of it.
        // Only watched, never swallowed; needs Accessibility, which we already ask for.
        escapeTaps.reset()
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53 && !event.isARepeat
            let time = event.timestamp
            MainActor.assumeIsolated { self?.handleGlobalKey(isEscape: isEscape, at: time) }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func handleGlobalKey(isEscape: Bool, at time: TimeInterval) {
        guard currentApp != nil, !isDismissing else { return }
        guard isEscape else {
            escapeTaps.reset()
            return
        }
        guard escapeTaps.press(at: time) else { return }
        lockLog.notice("Esc×3 while the card had no focus; going back")
        dismiss(result: .cancelled)
    }

    private func handleKey(keyCode: UInt16, characters: String?) {
        // Typing may start the moment the card appears, before it finishes animating.
        guard currentApp != nil, !isDismissing, !model.isVerifyingPIN else { return }
        switch keyCode {
        case 53: // esc
            dismiss(result: .cancelled)
        case _ where model.mode == .confirmingOwner:
            break
        case 51, 117: // delete, forward delete
            if !model.entered.isEmpty { model.entered.removeLast() }
        case 36, 76: // return, enter
            Task { await submit() }
        default:
            guard let chars = characters, chars.count == 1,
                  let ch = chars.first, ch.isASCII, ch.isNumber,
                  model.entered.count < model.pinLength else { return }
            model.entered.append(ch)
            model.message = nil
            if model.entered.count == model.pinLength {
                // Let the last dot fill in before checking.
                let generation = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                    guard let self, self.generation == generation else { return }
                    Task { await self.submit() }
                }
            }
        }
    }

    // MARK: - Window

    /// Each presentation gets a fresh window, so a window WindowServer has
    /// invalidated (e.g. around a Space switch) is never reused.
    private func makePanelIfNeeded() -> NotchPanel {
        if let panel { return panel }
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let host = FirstClickHostingView(rootView: NotchLockView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    private func dropPanel() {
        guard let old = panel else { return }
        old.orderOut(nil)
        old.contentView = nil
        panel = nil
    }

    /// The screen the user is looking at: the one with the mouse.
    private func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
