import Foundation

/// Pure decisions behind the lock guard and the lock card, kept free of AppKit
/// so they can be unit tested.
///
/// The ground rules they encode:
/// - A locked app is kept hidden by the guard, whether or not a card is up.
/// - Opening a locked app covers every display at once (the shield), so none
///   of it shows while the card comes up.
/// - Nothing ever captures input, and the shield only stays while a card is up
///   (switching to another app puts both away), so a card that macOS fails to
///   draw can never leave the Mac stuck.
enum LockPolicy {
    // MARK: - Guard

    struct GuardDecision: Equatable {
        var hide: Bool
        var cover: Bool
        static let leave = GuardDecision(hide: false, cover: false)
    }

    /// How long a locked app may stay visible despite hide requests before its
    /// windows are covered.
    static let coverAfter: TimeInterval = 0.5
    /// How long covers put up ahead of a full-screen app (while macOS switches to
    /// its Space) are kept before its window shows up.
    static let arrivalGrace: TimeInterval = 1.5
    /// A cover that WindowServer hasn't drawn for this long (once any Space
    /// switch has settled) counts as failed. Generous: a false failure hides the
    /// app, which makes macOS jump Spaces.
    static let coverMustDrawWithin: TimeInterval = 2
    static let spaceSwitchSettle: TimeInterval = 1

    /// What to do with one locked app on this tick.
    /// - `fullScreenOnActiveSpace`: one of its full-screen windows is on screen.
    ///   It's covered where it is, not hidden: hiding makes macOS jump to another
    ///   Space, then back again after the unlock.
    /// - `isCardTarget`: the user is opening it and its card is up. Until a window
    ///   shows, it's left alone: macOS may be switching to its full-screen Space,
    ///   and hiding it then would leave that Space empty. Normal windows are
    ///   still hidden (a hidden app shows nothing in Mission Control).
    /// - `coverFailed`: covers weren't drawn over it; fall back to hiding.
    static func guardDecision(
        isGuarded: Bool,
        isHidden: Bool,
        hasVisibleWindows: Bool,
        visibleFor seconds: TimeInterval,
        isCardTarget: Bool = false,
        fullScreenOnActiveSpace: Bool = false,
        coverFailed: Bool = false
    ) -> GuardDecision {
        guard isGuarded else { return .leave }
        if !coverFailed {
            if fullScreenOnActiveSpace { return GuardDecision(hide: false, cover: true) }
            if isCardTarget && !hasVisibleWindows { return .leave }
        }
        return GuardDecision(
            hide: !isHidden || hasVisibleWindows,
            cover: hasVisibleWindows && seconds >= coverAfter
        )
    }

    // MARK: - Shield

    /// How long the shield waits for a card once a locked app is opened, and
    /// how long it waits after the card closes for the app to finish hiding.
    static let shieldHold: TimeInterval = 1.5

    /// Whether the full-screen shield stays up on this tick.
    /// - `cardUp`: the card is asking for this app's PIN; the shield stays with it.
    /// - `cardClosed`: the card went away without unlocking; the shield comes
    ///   down as soon as the app is off screen.
    /// - Otherwise the app was just opened and its card is on its way.
    /// `secondsSinceHeld` counts from opening or from the card closing; the
    /// shield never outlasts `shieldHold` without a card, so it can't hold the Mac.
    static func keepShield(
        targetGuarded: Bool,
        cardUp: Bool,
        cardClosed: Bool,
        targetExposed: Bool,
        secondsSinceHeld: TimeInterval
    ) -> Bool {
        guard targetGuarded else { return false }
        if cardUp { return true }
        guard secondsSinceHeld < shieldHold else { return false }
        return cardClosed ? targetExposed : true
    }

    /// Only covers over real windows (not thin toolbar strips, which full-screen
    /// apps keep at the screen edge) tell whether covers are being drawn.
    static func coverShowsDrawing(width: CGFloat, height: CGFloat) -> Bool {
        width >= 200 && height >= 200
    }

    // MARK: - Card visibility

    /// Escalating steps when WindowServer isn't showing the card. None of them
    /// block anything; the locked app stays hidden by the guard meanwhile.
    enum CardRecovery: Int, Comparable {
        case none
        /// Order the card front again on the current Space.
        case reorder
        /// The locked app's full-screen Space is showing (empty, as the app is
        /// hidden): go back to the desktop, where the card can draw.
        case leaveFullScreenSpace
        /// Replace the card's window.
        case rebuild

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let maxRebuilds = 3

    /// The next step to take once the card has been invisible for `seconds`,
    /// given the last step already taken in this episode.
    static func cardRecovery(notVisibleFor seconds: TimeInterval, lastStep: CardRecovery, rebuilds: Int) -> CardRecovery {
        switch CardRecovery(rawValue: lastStep.rawValue + 1) {
        case .reorder? where seconds >= 0.35: .reorder
        case .leaveFullScreenSpace? where seconds >= 0.9: .leaveFullScreenSpace
        case .rebuild? where seconds >= 1.5 && rebuilds < maxRebuilds: .rebuild
        default: .none
        }
    }

    // MARK: - Card focus

    enum FocusResponse: Equatable {
        /// Take keyboard focus back.
        case reclaim
        /// The user moved on to another app: put the card away (the locked app stays hidden).
        case dismiss
        /// Leave focus where it is; the card shows "click to type your PIN".
        case ignore
        /// Just after a Space switch: macOS may have activated the app on the
        /// Space it landed on. Look again shortly before deciding.
        case recheckSoon
    }

    /// Right after a card appears (or is clicked) macOS is still handing focus
    /// around after hiding the locked app; losing focus then isn't the user's doing.
    static let focusHandoff: TimeInterval = 1.5

    /// Another app became active while a card is up. `isRegularApp`: it has a
    /// Dock icon, so the user can have switched to it; background agents and
    /// system dialogs (permission prompts, notification alerts) don't count.
    /// Past the hand-off, a regular app is the user's choice (⌘Tab) even if the
    /// card never had focus: the shield covers the screen, so keeping the card
    /// would keep the user from the app they picked.
    /// `secondsSinceSpaceChange`: macOS activates whichever app owns the Space
    /// it lands on, so an activation right after a Space switch isn't the user's.
    static func otherAppActivated(
        secondsSinceFocusRequest: TimeInterval,
        secondsSinceSpaceChange: TimeInterval = .infinity,
        isLockedTarget: Bool,
        isRegularApp: Bool = true
    ) -> FocusResponse {
        if isLockedTarget || secondsSinceFocusRequest < focusHandoff { return .reclaim }
        if secondsSinceSpaceChange < 1 { return .recheckSoon }
        // The user switched to another app: they changed their mind. A
        // background agent taking focus keeps the card so one click continues.
        return isRegularApp ? .dismiss : .ignore
    }

    // MARK: - After unlocking

    /// How long after unlocking to check that the app actually shows a window.
    static let reopenCheckDelay: TimeInterval = 0.4

    /// Activating an app doesn't reopen a closed window, or move to the desktop
    /// its window is on. If it shows nothing after the unlock, reopen it the way
    /// a Dock click does, unless the user has already moved on to another app.
    static func shouldReopenAfterUnlock(hasWindowOnScreen: Bool, userMovedOn: Bool) -> Bool {
        !hasWindowOnScreen && !userMovedOn
    }
}

/// "Forgot PIN?" on the lock card: once the Mac password has confirmed it's the
/// owner, type a new PIN, then the same PIN again.
struct PINResetFlow: Equatable {
    enum Step: Equatable {
        case choose
        case confirm(first: String)
    }

    enum Outcome: Equatable {
        /// Ask for the same PIN again.
        case confirmNext
        /// The two didn't match; start over.
        case mismatch
        case done(String)
    }

    private(set) var step = Step.choose

    mutating func submit(_ pin: String) -> Outcome {
        switch step {
        case .choose:
            step = .confirm(first: pin)
            return .confirmNext
        case .confirm(let first):
            step = .choose
            return pin == first ? .done(pin) : .mismatch
        }
    }
}
