import XCTest
@testable import PresencePolicy

final class LockPolicyTests: XCTestCase {
    // MARK: Guard

    private func decide(
        guarded: Bool = true, hidden: Bool = false, visible: Bool = true, for seconds: TimeInterval = 0,
        cardTarget: Bool = false, fullScreenHere: Bool = false, coverFailed: Bool = false
    ) -> LockPolicy.GuardDecision {
        LockPolicy.guardDecision(
            isGuarded: guarded, isHidden: hidden, hasVisibleWindows: visible, visibleFor: seconds,
            isCardTarget: cardTarget, fullScreenOnActiveSpace: fullScreenHere, coverFailed: coverFailed
        )
    }

    func testUnguardedAppsAreLeftAlone() {
        XCTAssertEqual(decide(guarded: false), .leave)
        XCTAssertEqual(decide(guarded: false, fullScreenHere: true), .leave)
    }

    func testVisibleLockedAppIsHiddenAtOnce() {
        XCTAssertEqual(decide(), LockPolicy.GuardDecision(hide: true, cover: false))
    }

    func testHiddenAppWithNothingOnScreenIsLeftAlone() {
        XCTAssertEqual(decide(hidden: true, visible: false), .leave)
    }

    func testUnhiddenWindowlessAppIsStillHidden() {
        XCTAssertEqual(decide(visible: false), LockPolicy.GuardDecision(hide: true, cover: false))
    }

    func testLockedAppThatRefusesToHideGetsCovered() {
        // Zen and Chrome web apps have refused AX hide (-25204) and stayed usable.
        XCTAssertEqual(decide(for: LockPolicy.coverAfter), LockPolicy.GuardDecision(hide: true, cover: true))
        // Reported hidden while its windows are still up: ask again and cover.
        XCTAssertEqual(decide(hidden: true, for: 1), LockPolicy.GuardDecision(hide: true, cover: true))
    }

    func testFullScreenAppOnTheCurrentSpaceIsCoveredNotHidden() {
        // Hiding it made macOS jump to another Space before and after every unlock.
        XCTAssertEqual(decide(fullScreenHere: true), LockPolicy.GuardDecision(hide: false, cover: true))
    }

    func testAppBeingOpenedWaitsToSeeWhereItsWindowLands() {
        // Hiding WhatsApp while macOS switched to its full-screen Space left that
        // Space empty; Claude, covered there, looked right.
        XCTAssertEqual(decide(visible: false, cardTarget: true), .leave)
        XCTAssertEqual(decide(cardTarget: true, fullScreenHere: true), LockPolicy.GuardDecision(hide: false, cover: true))
        // A normal window is hidden as usual.
        XCTAssertEqual(decide(cardTarget: true), LockPolicy.GuardDecision(hide: true, cover: false))
    }

    func testAppsAreHiddenWhenCoversCannotBeDrawn() {
        XCTAssertEqual(decide(fullScreenHere: true, coverFailed: true), LockPolicy.GuardDecision(hide: true, cover: false))
        XCTAssertEqual(decide(visible: false, cardTarget: true, coverFailed: true), LockPolicy.GuardDecision(hide: true, cover: false))
    }

    func testThinToolbarStripsDoNotJudgeWhetherCoversAreDrawn() {
        // Zen's 1920×68 full-screen toolbar strip made a working cover look failed.
        XCTAssertFalse(LockPolicy.coverShowsDrawing(width: 1920, height: 68))
        XCTAssertTrue(LockPolicy.coverShowsDrawing(width: 1920, height: 1080))
    }

    // MARK: Shield

    private func keep(
        guarded: Bool = true, cardUp: Bool = false, cardClosed: Bool = false,
        exposed: Bool = true, since seconds: TimeInterval = 0
    ) -> Bool {
        LockPolicy.keepShield(
            targetGuarded: guarded, cardUp: cardUp, cardClosed: cardClosed,
            targetExposed: exposed, secondsSinceHeld: seconds
        )
    }

    func testShieldStaysAsLongAsTheCardIsUp() {
        // Full screen or not: the app must never show while the PIN is asked for.
        XCTAssertTrue(keep(cardUp: true, since: 600))
        XCTAssertTrue(keep(cardUp: true, exposed: false, since: 600))
    }

    func testShieldComesDownTheMomentTheAppIsUnlocked() {
        XCTAssertFalse(keep(guarded: false, cardUp: true))
    }

    func testShieldWaitsForTheCardOfAnAppBeingOpened() {
        // Raised on launch, before the app has a window or its card exists.
        XCTAssertTrue(keep(exposed: false, since: 0.5))
    }

    func testShieldStaysUntilACancelledAppIsOffScreen() {
        XCTAssertTrue(keep(cardClosed: true, exposed: true, since: 0.3))
        XCTAssertFalse(keep(cardClosed: true, exposed: false, since: 0.3))
    }

    func testShieldNeverOutlastsItsHoldWithoutACard() {
        // An app that refuses to hide is covered window by window instead;
        // the screen is never held without a card to unlock it.
        XCTAssertFalse(keep(since: LockPolicy.shieldHold))
        XCTAssertFalse(keep(cardClosed: true, exposed: true, since: LockPolicy.shieldHold))
    }

    // MARK: Card visibility

    func testVisibleOrBrieflyMissingCardIsLeftAlone() {
        XCTAssertEqual(LockPolicy.cardRecovery(notVisibleFor: 0.2, lastStep: .none, rebuilds: 0), .none)
    }

    func testInvisibleCardRecoversStepByStep() {
        XCTAssertEqual(LockPolicy.cardRecovery(notVisibleFor: 0.4, lastStep: .none, rebuilds: 0), .reorder)
        XCTAssertEqual(LockPolicy.cardRecovery(notVisibleFor: 0.5, lastStep: .reorder, rebuilds: 0), .none)
        XCTAssertEqual(LockPolicy.cardRecovery(notVisibleFor: 1.0, lastStep: .reorder, rebuilds: 0), .leaveFullScreenSpace)
        XCTAssertEqual(LockPolicy.cardRecovery(notVisibleFor: 1.6, lastStep: .leaveFullScreenSpace, rebuilds: 0), .rebuild)
        XCTAssertEqual(LockPolicy.cardRecovery(notVisibleFor: 5, lastStep: .rebuild, rebuilds: 1), .none)
    }

    func testStepsAreNeverSkippedEvenAfterALongGap() {
        // A slow tick must not jump straight to rebuilding.
        XCTAssertEqual(LockPolicy.cardRecovery(notVisibleFor: 3, lastStep: .none, rebuilds: 0), .reorder)
    }

    func testRebuildingStopsAfterTheLimit() {
        XCTAssertEqual(
            LockPolicy.cardRecovery(notVisibleFor: 2, lastStep: .leaveFullScreenSpace, rebuilds: LockPolicy.maxRebuilds),
            .none
        )
    }

    // MARK: Focus

    func testFocusIsTakenBackWhileMacOSIsStillHandingItAround() {
        XCTAssertEqual(
            LockPolicy.otherAppActivated(secondsSinceFocusRequest: 0.3, isLockedTarget: false),
            .reclaim
        )
    }

    func testTheLockedAppComingBackAlwaysRefocusesTheCard() {
        XCTAssertEqual(
            LockPolicy.otherAppActivated(secondsSinceFocusRequest: 30, isLockedTarget: true),
            .reclaim
        )
    }

    func testSwitchingToAnotherAppPutsTheCardAway() {
        // ⌘Tab away from the card must never fight the user.
        XCTAssertEqual(
            LockPolicy.otherAppActivated(secondsSinceFocusRequest: 3, isLockedTarget: false),
            .dismiss
        )
    }

    func testSwitchingAwayPutsTheCardAwayEvenIfItNeverHadFocus() {
        // The shield covers the screen while the card is up; keeping the card
        // after ⌘Tab would keep the user from the app they picked.
        XCTAssertEqual(
            LockPolicy.otherAppActivated(secondsSinceFocusRequest: 3, isLockedTarget: false),
            .dismiss
        )
    }

    func testSystemDialogsAndBackgroundAgentsNeverPutTheCardAway() {
        // A permission prompt (UserNotificationCenter) dismissed the card in testing.
        XCTAssertEqual(
            LockPolicy.otherAppActivated(
                secondsSinceFocusRequest: 3, isLockedTarget: false, isRegularApp: false
            ),
            .ignore
        )
    }

    func testAppThatMacOSActivatesAfterASpaceSwitchIsCheckedAgainFirst() {
        // Landing on Zen's Space made macOS activate Zen, which closed the card.
        // A real ⌘Tab to an app on another desktop also switches Space, so the
        // card looks again shortly instead of deciding at once.
        XCTAssertEqual(
            LockPolicy.otherAppActivated(
                secondsSinceFocusRequest: 5, secondsSinceSpaceChange: 0.3,
                isLockedTarget: false
            ),
            .recheckSoon
        )
    }
}

final class ReopenAfterUnlockTests: XCTestCase {
    func testAppWithNoWindowIsReopened() {
        XCTAssertTrue(LockPolicy.shouldReopenAfterUnlock(hasWindowOnScreen: false, userMovedOn: false))
    }

    func testAppShowingAWindowIsLeftAlone() {
        XCTAssertFalse(LockPolicy.shouldReopenAfterUnlock(hasWindowOnScreen: true, userMovedOn: false))
    }

    func testNotReopenedOnceTheUserMovedOn() {
        XCTAssertFalse(LockPolicy.shouldReopenAfterUnlock(hasWindowOnScreen: false, userMovedOn: true))
    }
}

final class PINResetFlowTests: XCTestCase {
    func testMatchingPINsFinish() {
        var flow = PINResetFlow()
        XCTAssertEqual(flow.submit("1234"), .confirmNext)
        XCTAssertEqual(flow.step, .confirm(first: "1234"))
        XCTAssertEqual(flow.submit("1234"), .done("1234"))
    }

    func testMismatchStartsOver() {
        var flow = PINResetFlow()
        _ = flow.submit("1234")
        XCTAssertEqual(flow.submit("4321"), .mismatch)
        XCTAssertEqual(flow.step, .choose)
        XCTAssertEqual(flow.submit("5678"), .confirmNext)
        XCTAssertEqual(flow.submit("5678"), .done("5678"))
    }
}
