import SwiftUI

/// The rounded card that grows out of the notch. It follows the light / dark
/// appearance; collapsed it is always black, so it hides in the notch.
struct NotchLockView: View {
    let model: NotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = model.expanded ? model.expandedSize : model.notchSize

        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: model.expanded ? 26 : 10, style: .continuous)
                .fill(model.expanded ? Palette.notchCard : .black)
                .shadow(color: model.expanded ? Palette.notchShadow : .clear, radius: 20, y: 10)
                .overlay {
                    RoundedRectangle(cornerRadius: model.expanded ? 26 : 10, style: .continuous)
                        .strokeBorder((model.message == nil ? Palette.accent : Palette.danger).opacity(0.55), lineWidth: 1)
                        .opacity(model.expanded ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: model.expanded)
                        .animation(.easeInOut(duration: 0.2), value: model.message == nil)
                }

            if model.expanded {
                content
                    .padding(.top, model.notchSize.height + 6)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 18)
                    .transition(
                        .opacity
                            .combined(with: .scale(scale: 0.9, anchor: .top))
                            .animation(.easeOut(duration: 0.18))
                    )
            }
        }
        .frame(width: size.width, height: size.height)
        // A click anywhere on the card takes focus back from whatever app grabbed it.
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { model.onRefocus() }
        // Without a physical notch the collapsed pill fades rather than "hiding" in the notch.
        .opacity(model.visible ? (model.expanded || model.hasNotch ? 1 : 0) : 0)
        // With Reduce Motion the red outline and message say the PIN was wrong.
        .modifier(Shake(animatableData: reduceMotion ? 0 : CGFloat(model.attempts)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let icon = model.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 38, height: 38)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(model.message ?? subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(model.message != nil ? Palette.danger : Palette.textSecondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }

            Spacer(minLength: 10)

            PinDots(length: model.pinLength, filled: model.entered.count)
                .opacity(model.mode == .confirmingOwner ? 0.35 : 1)

            Group {
                if model.mode == .unlock {
                    Button(action: model.onForgotPIN) {
                        Text("Forgot PIN?")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.textSecondary)
                            .underline()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Confirm with your Mac password, then choose a new PIN")
                } else {
                    Color.clear
                }
            }
            .frame(height: 16)
            .padding(.top, 8)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                // A quiet hint, not a button: Touch ID is already listening.
                if model.biometricsAvailable, model.mode == .unlock {
                    Group {
                        if model.settled, model.biometrics.context != nil {
                            TouchIDGlyph(session: model.biometrics, controlSize: .small)
                        } else {
                            Image(systemName: "touchid")
                                .font(.system(size: 15))
                                .foregroundStyle(Palette.textSecondary.opacity(0.7))
                        }
                    }
                    .frame(width: 24, height: 24)
                }
                if let hint = model.focusHint {
                    // The card lost keyboard focus; make the fix one click away.
                    Button(action: model.onRefocus) {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text(hint)
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(Palette.warning)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                } else if model.mode != .unlock {
                    Text(model.mode == .confirmingOwner ? "Waiting for your Mac password…" : "Your locked apps will use the new PIN")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                } else {
                    Text(model.biometricsAvailable ? "Touch ID or type your PIN" : (model.touchIDNote.map { "\($0) · type your PIN" } ?? "Type your PIN"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button(action: model.onCancel) {
                    HStack(spacing: 6) {
                        Keycap(text: "esc")
                        Text("to cancel")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var title: String {
        switch model.mode {
        case .unlock, .confirmingOwner: "\(model.appName) is locked"
        case .newPIN, .confirmNewPIN: "Choose a new PIN"
        }
    }

    private var subtitle: String {
        switch model.mode {
        case .unlock: "Unlock to open it"
        case .confirmingOwner: "Confirm with your Mac password"
        case .newPIN: "Type a new \(model.pinLength)-digit PIN"
        case .confirmNewPIN: "Type the new PIN again"
        }
    }
}

struct Shake: GeometryEffect {
    var amount: CGFloat = 9
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(animatableData * .pi * shakes), y: 0))
    }
}

#Preview("Notch · Locked") {
    NotchLockView(model: .preview())
        .frame(width: 470, height: 260)
        .background(Color.gray.opacity(0.3))
}

#Preview("Notch · Wrong PIN") {
    NotchLockView(model: .preview(entered: "", message: "Wrong PIN, try again"))
        .frame(width: 470, height: 260)
        .background(Color.gray.opacity(0.3))
}

#Preview("Notch · New PIN") {
    let model = NotchModel.preview(entered: "12")
    model.mode = .newPIN
    return NotchLockView(model: model)
        .frame(width: 470, height: 260)
        .background(Color.gray.opacity(0.3))
}

#Preview("Notch · Lost focus") {
    let model = NotchModel.preview()
    model.focusHint = "Touch ID paused · click here to resume"
    return NotchLockView(model: model)
        .frame(width: 470, height: 260)
        .background(Color.gray.opacity(0.3))
}
