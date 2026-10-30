import CommonCrypto
import CryptoKit
import Foundation

/// Versioned, salted PBKDF2-HMAC-SHA256 storage for the local app PIN.
enum PinHasher {
    static let iterations: UInt32 = 250_000
    private static let prefix = "pbkdf2-sha256"

    static func make(_ pin: String) -> String {
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let derived = deriveKey(password: Data(pin.utf8), salt: salt, rounds: iterations)
        return "\(prefix)$\(iterations)$\(salt.base64EncodedString())$\(derived.base64EncodedString())"
    }

    static func verifies(_ pin: String, encoded: String) -> Bool {
        let fields = encoded.split(separator: "$", omittingEmptySubsequences: false)
        guard fields.count == 4,
              String(fields[0]) == prefix,
              let rounds = UInt32(fields[1]), rounds >= 1, rounds <= 1_000_000,
              let salt = Data(base64Encoded: String(fields[2])), salt.count >= 16,
              let expected = Data(base64Encoded: String(fields[3])), expected.count == 32 else { return false }
        let actual = deriveKey(password: Data(pin.utf8), salt: salt, rounds: rounds)
        return constantTimeEqual(actual, expected)
    }

    /// Used only to verify and migrate hashes written by the earlier app version.
    static func verifiesLegacy(_ pin: String, salt: Data, hexDigest: String) -> Bool {
        let actual = SHA256.hash(data: salt + Data(pin.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return actual == hexDigest
    }

    /// PBKDF2-HMAC-SHA256 with a 256-bit output, via CommonCrypto: ~35 ms for
    /// 250k rounds, against ~0.3 s (Release) and ~1 s (Debug) for the same
    /// derivation hand-rolled on CryptoKit HMAC, which made unlocking lag.
    static func deriveKey(password: Data, salt: Data, rounds: UInt32) -> Data {
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                    &derived, derived.count
                )
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return Data(derived)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}

/// Per-process exponential delay after repeated wrong PINs. Uses monotonic time,
/// so wall-clock changes cannot bypass the wait.
struct PINAttemptThrottle {
    private(set) var failures = 0
    private var blockedUntil: TimeInterval = 0

    func remainingDelay(at uptime: TimeInterval) -> TimeInterval {
        max(0, blockedUntil - uptime)
    }

    mutating func recordFailure(at uptime: TimeInterval) -> TimeInterval? {
        failures += 1
        guard failures >= 5 else { return nil }
        let exponent = min(failures - 5, 5)
        let delay = min(60, pow(2, Double(exponent + 1)))
        blockedUntil = uptime + delay
        return delay
    }

    mutating func reset() {
        failures = 0
        blockedUntil = 0
    }
}
