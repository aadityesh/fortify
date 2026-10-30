import XCTest
@testable import PresencePolicy

final class PresencePolicyTests: XCTestCase {
    func testFullscreenTimeoutRelocksWhenLeaveRelockingIsDisabled() {
        XCTAssertTrue(PresencePolicy.shouldRelockAfterLeaving(
            relockWhenLeaving: false, fullscreenGraceExpired: true
        ))
        XCTAssertFalse(PresencePolicy.shouldRelockAfterLeaving(
            relockWhenLeaving: false, fullscreenGraceExpired: false
        ))
        XCTAssertTrue(PresencePolicy.shouldRelockAfterLeaving(
            relockWhenLeaving: true, fullscreenGraceExpired: false
        ))
    }

    func testJustUnlockedAppIsNotRelockedBeforeItsFirstWindowAppears() {
        // A Chrome web app had no window 2s after unlock and was relocked as "closed".
        XCTAssertTrue(PresencePolicy.shouldWaitForFirstWindow(hasBeenOnScreen: false, secondsSinceWatchStarted: 2))
        XCTAssertFalse(PresencePolicy.shouldWaitForFirstWindow(hasBeenOnScreen: true, secondsSinceWatchStarted: 2))
        XCTAssertFalse(PresencePolicy.shouldWaitForFirstWindow(
            hasBeenOnScreen: false, secondsSinceWatchStarted: PresencePolicy.firstWindowGrace
        ))
    }

    func testWebAppsWaitForTheirFirstWindowWithoutATimeLimit() {
        // Some browsers draw the web app's window from the browser process, where
        // it's never seen; relocking after the grace would block it again.
        XCTAssertTrue(PresencePolicy.shouldWaitForFirstWindow(
            hasBeenOnScreen: false, secondsSinceWatchStarted: 600, isWebApp: true
        ))
        XCTAssertFalse(PresencePolicy.shouldWaitForFirstWindow(
            hasBeenOnScreen: true, secondsSinceWatchStarted: 1, isWebApp: true
        ))
    }

    func testRecognisesWebAppsFromChromiumBrowsersAndSafari() {
        // Chrome, Brave, Edge, Opera, Vivaldi: app_mode_loader stubs.
        for id in ["com.google.Chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod",
                   "com.brave.Browser.app.fhihpiojkbmbpdjeoajapmgkhlnakfjf",
                   "com.microsoft.edgemac.app.abc", "com.operasoftware.Opera.app.abc"] {
            XCTAssertTrue(PresencePolicy.isWebApp(
                bundleIdentifier: id, executableName: "app_mode_loader",
                info: ["CrAppModeShortcutID": "abc", "CrBundleIdentifier": "x"]
            ), id)
        }
        XCTAssertTrue(PresencePolicy.isWebApp(bundleIdentifier: "com.example.app", executableName: "x",
                                              info: ["CrAppModeShortcutID": "abc"]))
        XCTAssertTrue(PresencePolicy.isWebApp(bundleIdentifier: "com.apple.Safari.WebApp.1C2D3E4F",
                                              executableName: "Music", info: [:]))
        // Browsers themselves and ordinary apps are not web apps.
        for id in ["com.google.Chrome", "com.brave.Browser", "com.apple.Safari", "com.anthropic.claudefordesktop"] {
            XCTAssertFalse(PresencePolicy.isWebApp(bundleIdentifier: id, executableName: "Main", info: [:]), id)
        }
    }

    func testPBKDF2SHA256MatchesKnownVector() {
        let result = PinHasher.deriveKey(password: Data("password".utf8), salt: Data("salt".utf8), rounds: 1)
        XCTAssertEqual(result.map { String(format: "%02x", $0) }.joined(),
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    func testPINHashVerifiesOnlyTheOriginalPIN() {
        let encoded = PinHasher.make("2468")
        XCTAssertTrue(PinHasher.verifies("2468", encoded: encoded))
        XCTAssertFalse(PinHasher.verifies("1357", encoded: encoded))
    }

    func testPINThrottleAddsIncreasingDelayAfterRepeatedFailures() {
        var throttle = PINAttemptThrottle()
        for _ in 0..<4 { XCTAssertNil(throttle.recordFailure(at: 100)) }
        XCTAssertEqual(throttle.recordFailure(at: 100), 2)
        XCTAssertEqual(throttle.remainingDelay(at: 101), 1)
        XCTAssertEqual(throttle.recordFailure(at: 102), 4)
        XCTAssertEqual(throttle.remainingDelay(at: 103), 3)
        throttle.reset()
        XCTAssertEqual(throttle.failures, 0)
        XCTAssertEqual(throttle.remainingDelay(at: 103), 0)
    }

    func testFullscreenWindowParkedOnAnotherSpaceKeepsUnlock() {
        XCTAssertTrue(PresencePolicy.shouldKeepParkedUnlock(
            isParkedOnOtherSpace: true,
            hasAccessibilityWindows: true,
            hasUnminimizedWindow: true,
            hasWindowServerWindow: true,
            withinSpaceTransitionGrace: false
        ))
    }

    func testParkedWindowWithoutAXEntryUsesWindowServerFallback() {
        XCTAssertTrue(PresencePolicy.shouldKeepParkedUnlock(
            isParkedOnOtherSpace: true,
            hasAccessibilityWindows: false,
            hasUnminimizedWindow: false,
            hasWindowServerWindow: true,
            withinSpaceTransitionGrace: false
        ))
    }

    func testMinimizedWindowRelocksEvenIfWindowServerStillListsIt() {
        XCTAssertFalse(PresencePolicy.shouldKeepParkedUnlock(
            isParkedOnOtherSpace: true,
            hasAccessibilityWindows: true,
            hasUnminimizedWindow: false,
            hasWindowServerWindow: true,
            withinSpaceTransitionGrace: false
        ))
    }

    func testClosedLastWindowRelocksWhenNoWindowRemains() {
        XCTAssertFalse(PresencePolicy.shouldKeepParkedUnlock(
            isParkedOnOtherSpace: true,
            hasAccessibilityWindows: false,
            hasUnminimizedWindow: false,
            hasWindowServerWindow: false,
            withinSpaceTransitionGrace: false
        ))
    }

    func testStaleAccessibilityWindowDoesNotKeepClosedAppUnlocked() {
        XCTAssertFalse(PresencePolicy.shouldKeepParkedUnlock(
            isParkedOnOtherSpace: true,
            hasAccessibilityWindows: true,
            hasUnminimizedWindow: true,
            hasWindowServerWindow: false,
            withinSpaceTransitionGrace: false
        ))
    }

    func testRecentSpaceTransitionGetsShortGracePeriod() {
        XCTAssertTrue(PresencePolicy.shouldKeepParkedUnlock(
            isParkedOnOtherSpace: false,
            hasAccessibilityWindows: false,
            hasUnminimizedWindow: false,
            hasWindowServerWindow: false,
            withinSpaceTransitionGrace: true
        ))
    }

    func testParkedAppRelocksWhenConfiguredDurationExpires() {
        XCTAssertFalse(PresencePolicy.shouldKeepParkedUnlock(
            isParkedOnOtherSpace: true,
            hasAccessibilityWindows: true,
            hasUnminimizedWindow: true,
            hasWindowServerWindow: true,
            withinSpaceTransitionGrace: false,
            parkedUnlockExpired: true
        ))
    }

    func testExpiredParkedUnlockOverridesRecentSpaceTransitionGrace() {
        XCTAssertFalse(PresencePolicy.shouldKeepParkedUnlock(
            isParkedOnOtherSpace: true,
            hasAccessibilityWindows: true,
            hasUnminimizedWindow: true,
            hasWindowServerWindow: true,
            withinSpaceTransitionGrace: true,
            parkedUnlockExpired: true
        ))
    }

    func testUnparkedAppDoesNotKeepUnlockForOffscreenWindow() {
        XCTAssertFalse(PresencePolicy.shouldKeepParkedUnlock(
            isParkedOnOtherSpace: false,
            hasAccessibilityWindows: false,
            hasUnminimizedWindow: false,
            hasWindowServerWindow: true,
            withinSpaceTransitionGrace: false
        ))
    }
}
