import XCTest
@testable import PresencePolicy

final class TripleTapDetectorTests: XCTestCase {
    func testThreeQuickPressesFire() {
        var taps = TripleTapDetector()
        XCTAssertFalse(taps.press(at: 0))
        XCTAssertFalse(taps.press(at: 0.3))
        XCTAssertTrue(taps.press(at: 0.6))
        XCTAssertFalse(taps.press(at: 0.8), "starts a fresh sequence")
    }

    func testSlowPressesDontFire() {
        var taps = TripleTapDetector()
        XCTAssertFalse(taps.press(at: 0))
        XCTAssertFalse(taps.press(at: 0.3))
        XCTAssertFalse(taps.press(at: 1.0))
        XCTAssertFalse(taps.press(at: 1.3))
        XCTAssertTrue(taps.press(at: 1.6))
    }

    func testOtherKeysBreakTheSequence() {
        var taps = TripleTapDetector()
        _ = taps.press(at: 0)
        _ = taps.press(at: 0.2)
        taps.reset()
        XCTAssertFalse(taps.press(at: 0.4))
    }
}
