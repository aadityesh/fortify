import Foundation

/// A key pressed three times quickly. Esc×3 backs out of a lock card that has
/// lost keyboard focus.
struct TripleTapDetector: Equatable {
    static let maxGap: TimeInterval = 0.45

    private var count = 0
    private var last: TimeInterval = -.infinity

    /// Returns true on the third quick press.
    mutating func press(at time: TimeInterval) -> Bool {
        count = time - last <= Self.maxGap ? count + 1 : 1
        last = time
        guard count >= 3 else { return false }
        count = 0
        last = -.infinity
        return true
    }

    /// Any other key in between breaks the sequence.
    mutating func reset() {
        count = 0
        last = -.infinity
    }
}
