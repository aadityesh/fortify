import SwiftUI

// MARK: - Toggle

/// Capsule switch uses Fortify green to show an enabled protection setting.
struct GreenToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { configuration.isOn.toggle() }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Palette.accent : Palette.toggleOff)
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(configuration.isOn ? Palette.onAccent : Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

// MARK: - Buttons

struct PillButtonStyle: ButtonStyle {
    var fill: Color = Palette.accent
    var foreground: Color = Palette.onAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(foreground)
            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    var foreground: Color = Palette.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(foreground)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Switches between the current appearance and its counterpart. Landing on
/// what the Mac itself uses goes back to following it.
struct ThemeToggle: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        IconButton(systemName: isDark ? "sun.max" : "moon",
                   help: isDark ? "Switch to light mode" : "Switch to dark mode") {
            let wantsDark = !isDark
            state.theme = wantsDark == ThemePreference.systemIsDark ? .system : (wantsDark ? .dark : .light)
        }
    }
}

/// Square icon button used for secondary window actions.
struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 34, height: 34)
                .background(hovering ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hovering ? Palette.border : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Bits

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typo.mono)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Palette.border)
            )
    }
}

struct Card: ViewModifier {
    var radius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.border))
    }
}

extension View {
    func card(radius: CGFloat = 16) -> some View { modifier(Card(radius: radius)) }
}

/// Fortify's lime fortress shield on the same dark tile used in the app icon.
struct BrandMark: View {
    var size: CGFloat = 30
    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        FortressShape()
            .fill(Palette.lime, style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            // On the dark window the tile is lifted a touch and edged in lime,
            // like the app icon, so it doesn't vanish into the background.
            .background(Color.adaptive(light: 0x0A0C0A, dark: 0x1A1F1A), in: tile)
            .overlay(tile.strokeBorder(Palette.lime.opacity(0.22), lineWidth: max(0.5, size * 0.02)))
    }
}

/// Fortress shield (battlements on top, pointed base) with a keyhole cut out.
/// Fill with the even-odd rule. Same geometry as scripts/make_icon.swift.
struct FortressShape: Shape {
    func path(in rect: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var p = Path()
        let top: CGFloat = 0.2, notch: CGFloat = 0.28
        p.move(to: pt(0.2, top))
        for (a, b) in [(0.34, 0.43), (0.57, 0.66)] as [(CGFloat, CGFloat)] {
            p.addLine(to: pt(a, top))
            p.addLine(to: pt(a, notch))
            p.addLine(to: pt(b, notch))
            p.addLine(to: pt(b, top))
        }
        p.addLine(to: pt(0.8, top))
        p.addLine(to: pt(0.8, 0.5))
        p.addQuadCurve(to: pt(0.5, 0.85), control: pt(0.8, 0.75))
        p.addQuadCurve(to: pt(0.2, 0.5), control: pt(0.2, 0.75))
        p.closeSubpath()

        // Keyhole as one outline, so nothing overlaps.
        let r: CGFloat = 0.068, neck: CGFloat = 0.03
        let dy = (r * r - neck * neck).squareRoot()
        p.move(to: pt(0.5 + neck, 0.508 + dy))
        p.addArc(center: pt(0.5, 0.508), radius: r * rect.width,
                 startAngle: .radians(atan2(dy, neck)), endAngle: .radians(atan2(dy, -neck)), clockwise: true)
        p.addLine(to: pt(0.445, 0.69))
        p.addLine(to: pt(0.555, 0.69))
        p.closeSubpath()
        return p
    }
}

#Preview("Brand mark") {
    HStack(spacing: 20) {
        BrandMark(size: 28)
        BrandMark(size: 52)
        BrandMark(size: 120)
    }
    .padding(30)
}

// MARK: - PIN

struct PinDots: View {
    let length: Int
    let filled: Int
    var fill: Color = Palette.accent
    var empty: Color = Palette.toggleOff

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<length, id: \.self) { index in
                Circle()
                    .fill(index < filled ? fill : empty)
                    .frame(width: 12, height: 12)
                    .scaleEffect(index < filled ? 1.0 : 0.82)
                    .animation(.spring(response: 0.22, dampingFraction: 0.6), value: filled)
            }
        }
    }
}

/// Keyboard-driven PIN entry for the main window.
struct PinEntryField: View {
    @Binding var pin: String
    let length: Int
    var attempts: Int = 0
    /// Called when the PIN reaches `length` digits, or on Return.
    let onSubmit: (String) -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PinDots(length: length, filled: pin.count)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            // With Reduce Motion the error text alone says the PIN was wrong.
            .modifier(Shake(animatableData: reduceMotion ? 0 : CGFloat(attempts)))
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                if press.key == .delete {
                    if !pin.isEmpty { pin.removeLast() }
                    return .handled
                }
                if press.key == .return {
                    onSubmit(pin)
                    return .handled
                }
                guard press.characters.count == 1, let ch = press.characters.first,
                      ch.isASCII, ch.isNumber else { return .ignored }
                if pin.count < length { pin.append(ch) }
                return .handled
            }
            // Submit from the view update (not a delayed callback) so the
            // closure we call always belongs to the current view.
            .onChange(of: pin) { _, newValue in
                if newValue.count == length { onSubmit(newValue) }
            }
            .onAppear { focused = true }
            .onTapGesture { focused = true }
    }
}
