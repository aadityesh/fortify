import Foundation
import Observation

enum PINVerification {
    case accepted
    case rejected
    case lockedOut(seconds: Int)
}

/// Persists which apps are locked and the (salted, hashed) PIN.
@MainActor
@Observable
final class LockStore {
    private enum Key {
        static let locked = "lockedBundleIDs"
        static let pinHash = "pinHash"
        static let pinSalt = "pinSalt"
        static let pinLength = "pinLength"
        static let useTouchID = "useTouchID"
        static let relockWhenLeaving = "relockWhenLeaving"
        static let fullScreenUnlockDuration = "fullScreenUnlockDuration"
        static let lockShortcut = "lockShortcut"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var pinThrottle = PINAttemptThrottle()

    private(set) var lockedIDs: Set<String>
    /// The same apps in the order they were locked; the first one is the free one.
    private(set) var lockOrder: [String]
    private(set) var hasPIN: Bool
    private(set) var pinLength: Int

    var useTouchID: Bool {
        didSet { defaults.set(useTouchID, forKey: Key.useTouchID) }
    }

    /// Relock an unlocked app once it leaves the screen (minimized, hidden, or
    /// all windows closed). Off: it stays unlocked until sleep, screen lock or quit.
    var relockWhenLeaving: Bool {
        didSet {
            defaults.set(relockWhenLeaving, forKey: Key.relockWhenLeaving)
            onRelockWhenLeavingChange()
        }
    }
    @ObservationIgnored var onRelockWhenLeavingChange: () -> Void = {}

    /// How long a full-screen app may remain unlocked after it is parked on
    /// another Space. The timer starts when the app leaves the active Space.
    var fullScreenUnlockDuration: TimeInterval {
        didSet {
            defaults.set(fullScreenUnlockDuration, forKey: Key.fullScreenUnlockDuration)
            onFullScreenUnlockDurationChange(fullScreenUnlockDuration)
        }
    }
    @ObservationIgnored var onFullScreenUnlockDurationChange: (TimeInterval) -> Void = { _ in }

    /// Locks the unlocked app in front from anywhere. nil: off.
    var lockShortcut: KeyCombo? {
        didSet {
            defaults.set(try? JSONEncoder().encode(lockShortcut), forKey: Key.lockShortcut)
            onLockShortcutChange(lockShortcut)
        }
    }
    @ObservationIgnored var onLockShortcutChange: (KeyCombo?) -> Void = { _ in }
    /// macOS refused the shortcut (not saved; it's rechecked on every change).
    var lockShortcutRefused = false
    /// Settings is recording a new shortcut: the current one is let go meanwhile,
    /// or pressing it again would lock instead of being recorded.
    @ObservationIgnored var onRecordingShortcut: (Bool) -> Void = { _ in }

    init() {
        let order = defaults.stringArray(forKey: Key.locked) ?? []
        lockOrder = order
        lockedIDs = Set(order)
        hasPIN = defaults.string(forKey: Key.pinHash) != nil
        pinLength = max(4, defaults.integer(forKey: Key.pinLength))
        useTouchID = defaults.object(forKey: Key.useTouchID) as? Bool ?? true
        relockWhenLeaving = defaults.object(forKey: Key.relockWhenLeaving) as? Bool ?? true
        fullScreenUnlockDuration = defaults.object(forKey: Key.fullScreenUnlockDuration) as? TimeInterval ?? 300
        // Never set: the default. Turned off: stored as JSON null.
        if let data = defaults.data(forKey: Key.lockShortcut) {
            lockShortcut = try? JSONDecoder().decode(KeyCombo?.self, from: data)
        } else {
            lockShortcut = .lockAppDefault
        }
    }

    // MARK: Locked apps

    func isLocked(_ bundleID: String) -> Bool { lockedIDs.contains(bundleID) }

    func setLocked(_ bundleID: String, _ locked: Bool) {
        if locked {
            guard lockedIDs.insert(bundleID).inserted else { return }
            lockOrder.append(bundleID)
        } else {
            lockedIDs.remove(bundleID)
            lockOrder.removeAll { $0 == bundleID }
        }
        defaults.set(lockOrder, forKey: Key.locked)
    }

    // MARK: PIN

    func setPIN(_ pin: String) {
        defaults.set(PinHasher.make(pin), forKey: Key.pinHash)
        defaults.removeObject(forKey: Key.pinSalt)
        defaults.set(pin.count, forKey: Key.pinLength)
        hasPIN = true
        pinLength = pin.count
        pinThrottle.reset()
    }

    func verify(_ pin: String) async -> PINVerification {
        let now = ProcessInfo.processInfo.systemUptime
        let remaining = pinThrottle.remainingDelay(at: now)
        if remaining > 0 { return .lockedOut(seconds: Int(ceil(remaining))) }

        guard let stored = defaults.string(forKey: Key.pinHash) else {
            return recordWrongPIN(at: now)
        }
        let salt = defaults.string(forKey: Key.pinSalt).flatMap { Data(base64Encoded: $0) }
        let result = await Task.detached(priority: .userInitiated) {
            if stored.hasPrefix("pbkdf2-sha256$") {
                return (PinHasher.verifies(pin, encoded: stored), nil as String?)
            }
            guard let salt, PinHasher.verifiesLegacy(pin, salt: salt, hexDigest: stored) else {
                return (false, nil)
            }
            // Upgrade old fast hashes on the next successful unlock without
            // running the expensive derivation on the main/event-tap thread.
            return (true, PinHasher.make(pin))
        }.value

        guard result.0 else { return recordWrongPIN(at: now) }
        if let upgradedHash = result.1 {
            defaults.set(upgradedHash, forKey: Key.pinHash)
            defaults.removeObject(forKey: Key.pinSalt)
        }
        pinThrottle.reset()
        return .accepted
    }

    private func recordWrongPIN(at uptime: TimeInterval) -> PINVerification {
        guard let delay = pinThrottle.recordFailure(at: uptime) else { return .rejected }
        return .lockedOut(seconds: Int(delay))
    }
}
