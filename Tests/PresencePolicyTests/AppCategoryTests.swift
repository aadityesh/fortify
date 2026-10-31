import XCTest
@testable import PresencePolicy

final class AppCategoryTests: XCTestCase {
    func testUsesTheDeclaredCategory() {
        XCTAssertEqual(AppCategory.automatic(bundleID: "net.whatsapp.WhatsApp",
                                             declaredType: "public.app-category.social-networking"), .social)
        XCTAssertEqual(AppCategory.automatic(bundleID: "com.apple.Photos",
                                             declaredType: "public.app-category.photography"), .creative)
        XCTAssertEqual(AppCategory.automatic(bundleID: "x", declaredType: "Public.App-Category.Utilities"), .utilities)
    }

    func testEveryKindOfGameIsAGame() {
        XCTAssertEqual(AppCategory.automatic(bundleID: "com.apple.Chess",
                                             declaredType: "public.app-category.board-games"), .games)
        XCTAssertEqual(AppCategory.automatic(bundleID: "x", declaredType: "public.app-category.games"), .games)
    }

    func testKnownAppsOverrideTheirDeclaredCategory() {
        XCTAssertEqual(AppCategory.automatic(bundleID: "com.apple.Safari",
                                             declaredType: "public.app-category.productivity"), .browsers)
        XCTAssertEqual(AppCategory.automatic(bundleID: "com.google.Chrome", declaredType: nil), .browsers)
    }

    func testWebAppsGroupTogether() {
        XCTAssertEqual(AppCategory.automatic(bundleID: "com.google.Chrome.app.abc",
                                             declaredType: nil, isWebApp: true), .webApps)
    }

    func testMissingOrUnknownIsOther() {
        XCTAssertEqual(AppCategory.automatic(bundleID: "x", declaredType: nil), .other)
        XCTAssertEqual(AppCategory.automatic(bundleID: "x", declaredType: "public.app-category.unheard-of"), .other)
        XCTAssertEqual(AppCategory.automatic(bundleID: "x", declaredType: "garbage"), .other)
    }

    func testRawValuesAreStable() {
        // Stored in UserDefaults when the user moves an app; renaming a case loses that.
        XCTAssertEqual(AppCategory(rawValue: "social"), .social)
        XCTAssertEqual(AppCategory(rawValue: "webApps"), .webApps)
    }

    func testGreeting() {
        XCTAssertEqual(Greeting.text(name: "Aadi", hour: 8), "Good morning, Aadi")
        XCTAssertEqual(Greeting.text(name: "Aadi", hour: 12), "Good afternoon, Aadi")
        XCTAssertEqual(Greeting.text(name: " Aadi ", hour: 19), "Good evening, Aadi")
        XCTAssertEqual(Greeting.text(name: "Aadi", hour: 2), "Good evening, Aadi")
        XCTAssertEqual(Greeting.text(name: "  ", hour: 8), "Welcome back")
    }
}
