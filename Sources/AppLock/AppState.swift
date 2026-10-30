import AppKit
import Observation

@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        /// Onboarding: create the PIN.
        case setup
        /// Onboarding: grant Accessibility so locked apps can be hidden.
        case permissions
        case locked, unlocked
        /// Forgot PIN: the Mac password confirmed it's the owner; choose a new PIN.
        case resetPIN
    }

    let store = LockStore()
    let catalog = AppCatalog()

    var phase: Phase
    var showSettings = false
    /// Bumped by the "/" shortcut to focus the search field.
    var searchFocusToken = 0
    /// Set when quitting is allowed without unlocking (logout, explicit quit).
    var allowQuit = false

    /// Lock icon in the menu bar (top right).
    var showMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarIcon, forKey: "showMenuBarIcon")
            onMenuBarIconChange?(showMenuBarIcon)
        }
    }
    @ObservationIgnored var onMenuBarIconChange: ((Bool) -> Void)?

    /// System follows the Mac's light / dark setting; Light and Dark override it.
    var theme: ThemePreference {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "appearance")
            applyTheme()
        }
    }

    init() {
        phase = store.hasPIN ? .locked : .setup
        showMenuBarIcon = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
        theme = ThemePreference(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
        // The old "theme" was pinned by the sun/moon button without saying so,
        // which stopped Fortify following the Mac. Everyone starts on System once.
        UserDefaults.standard.removeObject(forKey: "theme")
    }

    func applyTheme() {
        NSApp.appearance = theme.appearance
    }

    func completeSetup(pin: String) {
        store.setPIN(pin)
        LoginItem.setEnabled(true)
        didAuthenticate()
    }

    /// Forgot PIN, once the Mac password has been confirmed.
    func completePINReset(pin: String) {
        store.setPIN(pin)
        lockLog.notice("PIN reset with the Mac password (main window)")
        didAuthenticate()
    }

    /// After a correct PIN / Touch ID. Accessibility is required, so without it the
    /// user lands on the permission step instead of the app list.
    func didAuthenticate() {
        if quitAfterUnlock {
            quit()
            return
        }
        lockLog.notice("Main window unlocked")
        phase = AppHider.hasAccessibility ? .unlocked : .permissions
    }

    /// "Lock all".
    func lockAll(_ bundleIDs: [String]) {
        for id in bundleIDs { store.setLocked(id, true) }
    }

    func setLocked(_ bundleID: String, _ locked: Bool) {
        store.setLocked(bundleID, locked)
    }

    /// Set when Quit was chosen while locked: quitting turns protection off, so it
    /// needs Touch ID / PIN first, then happens without asking again.
    var quitAfterUnlock = false

    /// Sends the user back to the permission step if Accessibility was revoked.
    func recheckAccessibility() {
        if phase == .unlocked && !AppHider.hasAccessibility { phase = .permissions }
    }

    func lock(reason: String = "locked") {
        if phase == .unlocked || phase == .permissions {
            lockLog.notice("Main window locked (\(reason, privacy: .public))")
        }
        phase = store.hasPIN ? .locked : .setup
        showSettings = false
    }

    func quit() {
        allowQuit = true
        // AppKit silently ignores terminate while a sheet (Settings) is attached,
        // so close it first and quit once it has animated away.
        showSettings = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSApp.terminate(nil)
            // terminate only returns if something cancelled it; quit regardless.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
        }
    }
}
