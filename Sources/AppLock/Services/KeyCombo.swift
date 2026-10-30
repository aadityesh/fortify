import Foundation

/// A keyboard shortcut: a physical key plus modifiers. Kept free of AppKit and
/// Carbon so its rules can be unit tested.
struct KeyCombo: Codable, Equatable, Sendable {
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    /// The virtual key code (the key's position, independent of the layout).
    var keyCode: UInt32
    var modifiers: Modifiers
    /// What's printed on the key, as typed when it was recorded ("L", "F5", "Space").
    var key: String

    /// ⌃⌘L: free in macOS and the common apps, and next to macOS's own ⌃⌘Q
    /// (Lock Screen). ⌘L would take the address bar from every browser.
    static let lockAppDefault = KeyCombo(keyCode: 0x25, modifiers: [.control, .command], key: "L")

    /// In the order macOS menus print them: ⌃⌥⇧⌘.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }

    /// The modifier mask `RegisterEventHotKey` takes (cmdKey, shiftKey, optionKey, controlKey).
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= 0x0100 }
        if modifiers.contains(.shift) { mask |= 0x0200 }
        if modifiers.contains(.option) { mask |= 0x0800 }
        if modifiers.contains(.control) { mask |= 0x1000 }
        return mask
    }

    /// Why this can't be the lock shortcut, or nil if it can. It's taken
    /// system-wide, so it mustn't swallow typing or an everyday command.
    static func problem(keyCode: UInt32, modifiers: Modifiers) -> String? {
        guard modifiers.contains(.command) || modifiers.contains(.control) else {
            return "Include ⌘ or ⌃. With only ⌥ or ⇧ the keys type a character (⌥L types ¬ or @)."
        }
        if modifiers == [.command], reservedCommandKeys.contains(keyCode) {
            return "That's an everyday shortcut in every app. Add ⌃ or ⌥ to it."
        }
        return nil
    }

    /// Q W S A Z X C V, Tab and Space with ⌘ alone.
    private static let reservedCommandKeys: Set<UInt32> = [
        0x0C, 0x0D, 0x01, 0x00, 0x06, 0x07, 0x08, 0x09, 0x30, 0x31,
    ]
}
