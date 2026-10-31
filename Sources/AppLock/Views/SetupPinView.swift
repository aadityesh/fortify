import SwiftUI

/// First-run screen: create the PIN and choose whether to use Touch ID.
struct SetupPinView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var store = state.store

        PinCreationFlow(
            createTitle: "Create a PIN",
            createSubtitle: "You'll use it, or Touch ID, to open Fortify and any app you lock.",
            showsMark: true,
            // Clear the window's traffic lights.
            barInsets: EdgeInsets(top: 38, leading: 18, bottom: 0, trailing: 18),
            trailingBarItem: AnyView(ThemeToggle()),
            footer: Biometrics.isSupported ? AnyView(TouchIDToggleRow(isOn: $store.useTouchID)) : nil,
            onComplete: { state.completeSetup(pin: $0) }
        )
    }
}

/// Forgot PIN: shown after the Mac password confirmed it's the owner.
struct ResetPinView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        PinCreationFlow(
            createTitle: "Choose a new PIN",
            createSubtitle: "Your Mac password confirmed it's you. Your locked apps stay locked with the new PIN.",
            showsMark: true,
            barInsets: EdgeInsets(top: 38, leading: 18, bottom: 0, trailing: 18),
            trailingBarItem: AnyView(
                Button("Cancel") { state.lock(reason: "PIN reset cancelled") }
                    .buttonStyle(.plain)
                    .font(Typo.bodyMedium)
                    .foregroundStyle(Palette.textSecondary)
            ),
            onComplete: { state.completePINReset(pin: $0) }
        )
    }
}

/// "Use Touch ID" row shown under the PIN on onboarding.
private struct TouchIDToggleRow: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "touchid")
                .font(.system(size: 18))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Use Touch ID")
                    .font(Typo.bodyMedium)
                Text("Unlock with your fingerprint. Your PIN always works too.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 12)
            Toggle("Use Touch ID", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(GreenToggleStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .card(radius: 12)
    }
}

/// Enter a new PIN, then confirm it. Shared by onboarding and Settings → Change PIN.
/// Fills its container; the back arrow and theme control sit in the top corners.
struct PinCreationFlow: View {
    let createTitle: String
    let createSubtitle: String
    var showsMark = false
    var barInsets = EdgeInsets()
    var trailingBarItem: AnyView?
    /// Shown under the Continue button on the first step.
    var footer: AnyView?
    let onComplete: (String) -> Void

    private enum Step { case create, confirm }

    private enum PinLength: Int, CaseIterable {
        case four = 4, six = 6
        var label: String { "\(rawValue) digits" }
    }

    @State private var step = Step.create
    @State private var length = PinLength.four
    @State private var pin = ""
    @State private var first = ""
    @State private var error: String?
    @State private var attempts = 0

    private var currentLength: Int { step == .create ? length.rawValue : first.count }
    private var canContinue: Bool { pin.count == currentLength }

    var body: some View {
        VStack(spacing: 18) {
            if showsMark {
                BrandMark(size: 52)
                    .padding(.bottom, 4)
            }

            VStack(spacing: 8) {
                Text(step == .create ? createTitle : "Confirm your PIN")
                    .font(Typo.display(34))
                Text(step == .create ? createSubtitle : "Type the same \(first.count) digits again.")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step == .create {
                SegmentedPills(options: PinLength.allCases, selection: $length, title: \.label)
            }

            PinEntryField(pin: $pin, length: currentLength, attempts: attempts, onSubmit: submit)
                .id("\(step)-\(currentLength)")

            Text(error ?? " ")
                .font(Typo.caption)
                .foregroundStyle(Palette.danger)

            Button("Continue") { submit(pin) }
                .buttonStyle(PillButtonStyle())
                .font(Typo.bodyMedium)
                .disabled(!canContinue)
                .opacity(canContinue ? 1 : 0.45)
                .animation(.easeOut(duration: 0.15), value: canContinue)

            if step == .create, let footer {
                footer
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if step == .confirm {
                HStack {
                    IconButton(systemName: "arrow.left", help: "Back", action: goBack)
                    Spacer()
                    trailingBarItem
                }.padding(barInsets)
            } else if let trailingBarItem {
                HStack {
                    Spacer()
                    trailingBarItem
                }.padding(barInsets)
            }
        }
        .animation(.easeOut(duration: 0.2), value: step)
        .onChange(of: length) {
            pin = ""
            error = nil
        }
    }

    private func submit(_ value: String) {
        guard value.count == currentLength else { return }
        switch step {
        case .create:
            first = value
            pin = ""
            error = nil
            step = .confirm
        case .confirm:
            if value == first {
                onComplete(value)
            } else {
                pin = ""
                error = "Those PINs didn't match. Try again."
                withAnimation(.linear(duration: 0.4)) { attempts += 1 }
            }
        }
    }

    private func goBack() {
        step = .create
        pin = ""
        first = ""
        error = nil
    }
}

#Preview("Onboarding · Light") {
    SetupPinView()
        .environment(AppState.preview(.setup))
        .frame(width: 760, height: 680)
        .background(Palette.background)
        .preferredColorScheme(.light)
}

#Preview("Onboarding · Dark") {
    SetupPinView()
        .environment(AppState.preview(.setup))
        .frame(width: 760, height: 680)
        .background(Palette.background)
        .preferredColorScheme(.dark)
}
