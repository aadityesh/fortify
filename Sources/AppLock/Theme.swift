import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// A color that resolves against the view's or window's effective macOS appearance.
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        }
    }
}

extension Color {
    /// A color that resolves against the window's effective macOS appearance.
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: .adaptive(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(hex: value, alpha: alpha))
    }
}

/// Fortify's warm paper and charcoal surfaces pair with forest green in light
/// appearance and lime in dark appearance. Green is reserved for protection
/// state and the main action.
enum Palette {
    static let background    = Color.adaptive(light: 0xF4F3EE, dark: 0x0A0C0A)
    static let surface       = Color.adaptive(light: 0xFFFFFF, dark: 0x111411)
    static let surfaceMuted  = Color.adaptive(light: 0xECEBE4, dark: 0x181C18)
    static let border        = Color.adaptive(light: 0xE6E4DC, dark: 0x1F241F)
    static let textPrimary   = Color.adaptive(light: 0x111411, dark: 0xF2F4EF)
    static let textSecondary = Color.adaptive(light: 0x6B6F68, dark: 0x8A918A)
    static let accent        = Color.adaptive(light: 0x0F3B2E, dark: 0xD4F57A)
    static let onAccent      = Color.adaptive(light: 0xFFFFFF, dark: 0x0A0C0A)
    static let toggleOff     = Color.adaptive(light: 0xD9D7CE, dark: 0x2A302A)
    static let positiveFill  = Color.adaptive(light: 0xDDF1E3, dark: 0x15291C)
    static let positiveText  = Color.adaptive(light: 0x1B7A43, dark: 0x8BE3A8)
    static let danger        = Color.adaptive(light: 0xC9423C, dark: 0xF0716B)
    static let hover         = Color.adaptive(light: 0xF7F6F2, dark: 0x151915)
    /// Amber, not green: a heads-up, not protection.
    static let warning       = Color.adaptive(light: 0x8A5A00, dark: 0xF5C451)

    /// The lock card under the notch. Black in dark appearance, so it grows
    /// seamlessly out of the notch; white in light.
    static let notchCard     = Color.adaptive(light: 0xFFFFFF, dark: 0x000000)
    static let notchShadow   = Color.adaptive(light: 0x000000, dark: 0x000000, lightAlpha: 0.18, darkAlpha: 0.35)

    /// The brand mark's tile is always dark, so it always uses the lime.
    static let lime = Color.hex(0xD4F57A)
}

enum Typo {
    /// Big headings in SF Pro (the system font).
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 11.5)
    static let mono = Font.system(size: 11, weight: .medium)
}

enum ThemePreference: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The Mac's own setting (System Settings → Appearance), whatever Fortify uses.
    static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

