import SwiftUI

/// Gate in front of AppLock's own window.
struct UnlockView: View {
    @Environment(AppState.self) private var state

    @State private var pin = ""
    @State private var error: String?
    @State private var attempts = 0
    @State private var isVerifyingPIN = false
    @State private var biometrics = BiometricSession()
    @State private var touchIDUnavailableReason: String?
    @State private var ownerCheck = OwnerCheck()
    /// Refreshed whenever Touch ID is (re)started, not on every keystroke:
    /// reading it asks coreauthd.
    @State private var touchIDAvailable = false

    var body: some View {
        VStack(spacing: 22) {
            BrandMark(size: 52)

            VStack(spacing: 8) {
                Text("Welcome back")
                    .font(Typo.display(34))
                Text(state.quitAfterUnlock ? "Unlock to quit AppLock." : "Type your PIN to unlock AppLock.")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
            }

            PinEntryField(pin: $pin, length: state.store.pinLength, attempts: attempts, onSubmit: submit)
                .disabled(isVerifyingPIN)

            if touchIDAvailable {
                touchIDHint
            }

            Text(error ?? " ")
                .font(Typo.caption)
                .foregroundStyle(Palette.danger)

            Button(action: forgotPIN) {
                Text("Forgot PIN?")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .underline()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Confirm with your Mac password, then choose a new PIN")
        }
        .padding(40)
        .frame(maxWidth: 440)
        .onAppear {
            startTouchIDIfPossible()
        }
        // e.g. the lid was opened while this screen was up.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if biometrics.context == nil { startTouchIDIfPossible() }
        }
        // The window is kept when closed, so this view stays mounted: start Touch ID
        // when it's shown again, and stop it whenever the window goes away.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard (note.object as? NSWindow)?.canBecomeMain == true else { return }
            if biometrics.context == nil { startTouchIDIfPossible() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow)?.canBecomeMain == true {
                biometrics.cancel()
                ownerCheck.cancel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in
            biometrics.cancel()
        }
        .onDisappear {
            biometrics.cancel()
            ownerCheck.cancel()
        }
    }

    /// A quiet suggestion rather than a button: while the glyph shows, Touch ID
    /// is already listening. If it stopped, clicking the hint starts it again.
    private var touchIDHint: some View {
        HStack(spacing: 8) {
            if let reason = touchIDUnavailableReason {
                Image(systemName: "touchid")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.textSecondary.opacity(0.5))
                Text(reason)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            } else if biometrics.context != nil {
                TouchIDGlyph(session: biometrics, controlSize: .small)
                Text("Or use Touch ID")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Button(action: requestTouchID) {
                    HStack(spacing: 6) {
                        Image(systemName: "touchid")
                            .font(.system(size: 15))
                        Text("Try Touch ID again")
                            .font(Typo.caption)
                    }
                    .foregroundStyle(Palette.textSecondary)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// True only while AppLock's window is on screen and focused. Touch ID must
    /// never unlock a closed or minimized window: AppLock also becomes active for
    /// the notch card, and that fingerprint is meant for the locked app.
    private var windowIsShowing: Bool {
        NSApp.windows.contains { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized && $0.isKeyWindow }
    }

    private func startTouchIDIfPossible() {
        let status = Biometrics.status
        touchIDAvailable = state.store.useTouchID && status.isSupported
        touchIDUnavailableReason = Biometrics.unavailableReason(status)
        // Never alongside the Mac password dialog.
        guard touchIDAvailable, touchIDUnavailableReason == nil, !isRunningForPreviews, windowIsShowing,
              !ownerCheck.isRunning else { return }
        requestTouchID()
    }

    private func requestTouchID() {
        error = nil
        biometrics.begin(reason: "unlock Fortify My Mac") { result in
            switch result {
            case .success:
                guard windowIsShowing else {
                    lockLog.notice("Ignored Touch ID for Fortify My Mac's window: it isn't showing")
                    return
                }
                state.didAuthenticate()
            case .noMatch, .failed, .cancelled: error = "Touch ID didn't work. Use your PIN."
            case .interrupted: break
            }
        }
    }

    /// Forgot PIN: the Mac password (or Touch ID) proves it's the owner, then a new PIN is chosen.
    private func forgotPIN() {
        biometrics.cancel()
        error = nil
        ownerCheck.begin(reason: "reset your Fortify My Mac PIN") { result in
            switch result {
            case .success:
                state.phase = .resetPIN
            case .noMatch, .failed:
                error = "Couldn't confirm your Mac password."
            case .cancelled, .interrupted:
                startTouchIDIfPossible()
            }
        }
    }

    private func submit(_ value: String) {
        guard !isVerifyingPIN else { return }
        isVerifyingPIN = true
        Task {
            let result = await state.store.verify(value)
            switch result {
            case .accepted:
                state.didAuthenticate()
            case .rejected:
                pin = ""
                error = "Wrong PIN, try again."
                withAnimation(.linear(duration: 0.4)) { attempts += 1 }
            case .lockedOut(let seconds):
                pin = ""
                error = "Too many attempts. Try again in \(seconds) seconds."
            }
            isVerifyingPIN = false
        }
    }
}

#Preview("Unlock · Light") {
    UnlockView()
        .environment(AppState.preview(.locked))
        .frame(width: 760, height: 680)
        .background(Palette.background)
        .preferredColorScheme(.light)
}

#Preview("Unlock · Dark") {
    UnlockView()
        .environment(AppState.preview(.locked))
        .frame(width: 760, height: 680)
        .background(Palette.background)
        .preferredColorScheme(.dark)
}
