import XCTest
@testable import PresencePolicy

final class KeyComboTests: XCTestCase {
    private let l: UInt32 = 0x25
    private let q: UInt32 = 0x0C

    func testDefaultIsControlCommandL() {
        XCTAssertEqual(KeyCombo.lockAppDefault.display, "⌃⌘L")
        XCTAssertNil(KeyCombo.problem(keyCode: l, modifiers: KeyCombo.lockAppDefault.modifiers))
    }

    func testDisplayUsesMenuOrder() {
        let combo = KeyCombo(keyCode: l, modifiers: [.command, .shift, .option, .control], key: "L")
        XCTAssertEqual(combo.display, "⌃⌥⇧⌘L")
    }

    func testCarbonModifierMask() {
        XCTAssertEqual(KeyCombo.lockAppDefault.carbonModifiers, 0x1000 | 0x0100)
        XCTAssertEqual(KeyCombo(keyCode: l, modifiers: [.option, .shift], key: "L").carbonModifiers, 0x0800 | 0x0200)
    }

    func testCombosThatTypeACharacterAreRefused() {
        XCTAssertNotNil(KeyCombo.problem(keyCode: l, modifiers: [.option]))
        XCTAssertNotNil(KeyCombo.problem(keyCode: l, modifiers: [.shift]))
        XCTAssertNotNil(KeyCombo.problem(keyCode: l, modifiers: [.option, .shift]))
        XCTAssertNotNil(KeyCombo.problem(keyCode: l, modifiers: []))
    }

    func testEverydayCommandShortcutsAreRefused() {
        XCTAssertNotNil(KeyCombo.problem(keyCode: q, modifiers: [.command]))
        // Fine once another modifier makes it distinct.
        XCTAssertNil(KeyCombo.problem(keyCode: q, modifiers: [.command, .option]))
    }

    func testCommandLIsAllowedIfChosen() {
        XCTAssertNil(KeyCombo.problem(keyCode: l, modifiers: [.command]))
    }

    func testSurvivesSavingAndTurningOff() throws {
        let saved = try JSONEncoder().encode(KeyCombo.lockAppDefault as KeyCombo?)
        XCTAssertEqual(try JSONDecoder().decode(KeyCombo?.self, from: saved), .lockAppDefault)
        let off = try JSONEncoder().encode(nil as KeyCombo?)
        XCTAssertNil(try JSONDecoder().decode(KeyCombo?.self, from: off))
    }
}
