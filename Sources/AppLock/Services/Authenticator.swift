import Foundation
import IOKit
import LocalAuthentication
import Observation

enum BiometricResult {
    case success
    /// The user cancelled Touch ID.
    case cancelled
    /// We cancelled it ourselves (e.g. the notch was dismissed). Ignore.
    case interrupted
    /// The finger didn't match (worth trying again).
    case noMatch
    case failed
}

enum Biometrics {
    enum Status {
        case ready
        /// Hardware and fingerprints exist but can't be used this moment
        /// (lid closed with an external display, too many failed tries, …).
        case unavailableNow
        case notEnrolled
        case unsupported

        /// Touch ID with fingerprints enrolled, even if it can't be used right now.
        var isSupported: Bool { self == .ready || self == .unavailableNow }
    }

    /// Asks coreauthd, so read it once per screen or card, not on every redraw.
    static var status: Status {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return .ready }
        switch LAError.Code(rawValue: error?.code ?? 0) {
        case .biometryNotEnrolled:
            return .notEnrolled
        case .biometryNotAvailable where context.biometryType == .none:
            return .unsupported
        default:
            return context.biometryType == .none ? .unsupported : .unavailableNow
        }
    }

    /// The Mac has Touch ID with fingerprints enrolled, even if it can't be used right now.
    static var isSupported: Bool { status.isSupported }

    /// True when the MacBook lid is closed (e.g. using an external display).
    /// macOS turns the built-in Touch ID sensor off in that state.
    static var isLidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    /// Why Touch ID can't be used at this moment, or nil if it can.
    static var unavailableReason: String? { unavailableReason(status) }

    static func unavailableReason(_ status: Status) -> String? {
        switch status {
        case .ready: nil
        case .unavailableNow: isLidClosed ? "Touch ID is off while the lid is closed" : "Touch ID isn't available right now"
        case .notEnrolled, .unsupported: nil
        }
    }

    /// Whether to offer Touch ID. A temporary failure still offers it; if the
    /// prompt can't run, the UI falls back to the PIN.
    static func shouldOffer(enabled: Bool) -> Bool { enabled && isSupported }
}

/// One Touch ID request at a time, shown inline by `TouchIDGlyph` instead of the
/// system dialog.
///
/// Flow: `begin` creates a context and publishes it; the view embeds a
/// `LAAuthenticationView` paired with that context and calls `glyphMounted` once
/// it's in a window; only then is the policy evaluated. Evaluating earlier (or
/// without a mounted view) would make macOS fall back to the system dialog.
@MainActor
@Observable
final class BiometricSession {
    private(set) var context: LAContext?

    private typealias Request = (reason: String, retries: Int, completion: (BiometricResult) -> Void)
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var evaluating: Request?

    /// Starts listening for a fingerprint. `retries` restarts after failed matches.
    func begin(reason: String, retries: Int = 1, completion: @escaping (BiometricResult) -> Void) {
        cancel()
        pending = (reason, retries, completion)
        context = LAContext()
    }

    func glyphMounted(for mounted: LAContext) {
        guard mounted === context, let pending else { return }
        self.pending = nil
        evaluating = pending

        // Only Sendable values cross into LocalAuthentication's callback queue.
        let token = ObjectIdentifier(mounted)
        mounted.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: pending.reason) { [weak self] ok, error in
            let result: BiometricResult
            if ok {
                result = .success
            } else {
                switch (error as? LAError)?.code {
                case .userCancel: result = .cancelled
                case .authenticationFailed: result = .noMatch
                case .appCancel, .systemCancel: result = .interrupted
                default: result = .failed
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(result, token: token) }
            }
        }
    }

    private func finish(_ result: BiometricResult, token: ObjectIdentifier) {
        guard let context, ObjectIdentifier(context) == token, let request = evaluating else { return }
        evaluating = nil
        // Retry only a genuine mismatch, never a setup failure, to avoid a cancel/recreate loop.
        if result == .noMatch, request.retries > 0 {
            begin(reason: request.reason, retries: request.retries - 1, completion: request.completion)
            return
        }
        self.context = nil
        request.completion(result)
    }

    func cancel() {
        pending = nil
        evaluating = nil
        context?.invalidate()
        context = nil
    }
}

/// Confirms the Mac's owner with the system dialog (login password, or Touch
/// ID). Used to reset a forgotten PIN, so it works even with Touch ID off.
@MainActor
final class OwnerCheck {
    private var context: LAContext?

    var isRunning: Bool { context != nil }

    func begin(reason: String, completion: @escaping (BiometricResult) -> Void) {
        cancel()
        let context = LAContext()
        self.context = context
        let token = ObjectIdentifier(context)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] ok, error in
            let result: BiometricResult
            if ok {
                result = .success
            } else {
                switch (error as? LAError)?.code {
                case .userCancel: result = .cancelled
                case .authenticationFailed: result = .noMatch
                case .appCancel, .systemCancel: result = .interrupted
                default: result = .failed
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A newer request (or cancel) replaced this one.
                    guard let self, let current = self.context, ObjectIdentifier(current) == token else { return }
                    self.context = nil
                    completion(result)
                }
            }
        }
    }

    func cancel() {
        context?.invalidate()
        context = nil
    }
}
