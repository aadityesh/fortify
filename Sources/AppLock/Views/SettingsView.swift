import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var startAtLogin = LoginItem.isEnabled
    @State private var loginMessage: String?
    @State private var changingPIN = false
    @State private var pinChanged = false
    @State private var hasAccessibility = AppHider.hasAccessibility
    /// Read on open and when the app comes back, not per redraw (it asks coreauthd).
    @State private var touchID = Biometrics.status
    @State private var shortcutMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(changingPIN ? "Change PIN" : "Settings")
                    .font(Typo.display(28))
                Spacer()
                Button(changingPIN ? "Cancel" : "Done") {
                    if changingPIN { changingPIN = false } else { dismiss() }
                }
                .buttonStyle(OutlineButtonStyle())
                .font(Typo.bodyMedium)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 20)

            if changingPIN {
                PinCreationFlow(
                    createTitle: "New PIN",
                    createSubtitle: "Choose a 4 or 6 digit PIN.",
                    onComplete: { pin in
                        state.store.setPIN(pin)
                        pinChanged = true
                        changingPIN = false
                    }
                )
                .frame(height: 380)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !hasAccessibility { accessibilityWarning }
                        unlockingSection
                        lockingSection
                        generalSection
                        quitFooter
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(24)
        .frame(width: 600, height: 640)
        .background(Palette.background)
        .foregroundStyle(Palette.textPrimary)
        .onAppear(perform: refreshLoginMessage)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibility = AppHider.hasAccessibility
            touchID = Biometrics.status
        }
        .onChange(of: startAtLogin) { _, enabled in
            if let error = LoginItem.setEnabled(enabled) {
                loginMessage = "Couldn't update: \(error)"
                startAtLogin = LoginItem.isEnabled
            } else {
                refreshLoginMessage()
            }
        }
    }

    // MARK: - Sections

    /// Only shown when it's missing: with it allowed there's nothing to do.
    private var accessibilityWarning: some View {
        row(
            title: "Accessibility is off",
            subtitle: "Some locked apps may stay visible behind the lock until you allow it."
        ) {
            Button("Allow") { AppHider.requestAccessibility() }
                .buttonStyle(OutlineButtonStyle(foreground: Palette.danger))
                .font(Typo.bodyMedium)
        }
        .card()
    }

    private var unlockingSection: some View {
        @Bindable var store = state.store
        return section("Unlocking") {
            row(title: "Touch ID", subtitle: touchIDSubtitle) {
                Toggle("Touch ID", isOn: $store.useTouchID)
                    .labelsHidden()
                    .toggleStyle(GreenToggleStyle())
                    .disabled(!touchID.isSupported)
                    .opacity(touchID.isSupported ? 1 : 0.4)
            }
            divider
            row(title: "PIN", subtitle: pinChanged ? "PIN updated." : "\(store.pinLength) digits.") {
                Button("Change PIN") { changingPIN = true }
                    .buttonStyle(OutlineButtonStyle())
                    .font(Typo.bodyMedium)
            }
        }
    }

    private var lockingSection: some View {
        @Bindable var store = state.store
        return section("Locking") {
            row(
                title: "Relock when I leave an app",
                subtitle: store.relockWhenLeaving
                    ? "Minimizing, hiding or closing an unlocked app locks it again."
                    : "Unlocked apps stay unlocked until your Mac sleeps or locks, or the app quits."
            ) {
                Toggle("Relock when I leave an app", isOn: $store.relockWhenLeaving)
                    .labelsHidden()
                    .toggleStyle(GreenToggleStyle())
            }
            divider
            row(
                title: "Full-screen apps",
                subtitle: "How long one stays unlocked after you switch to another desktop."
            ) {
                Picker("Full-screen apps stay unlocked for", selection: $store.fullScreenUnlockDuration) {
                    Text("1 minute").tag(TimeInterval(60))
                    Text("5 minutes").tag(TimeInterval(300))
                    Text("10 minutes").tag(TimeInterval(600))
                    Text("15 minutes").tag(TimeInterval(900))
                    Text("30 minutes").tag(TimeInterval(1800))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            divider
            row(title: "Lock shortcut", subtitle: shortcutSubtitle) {
                ShortcutRecorder(
                    shortcut: $store.lockShortcut,
                    message: $shortcutMessage,
                    onRecording: { state.store.onRecordingShortcut($0) }
                )
            }
        }
    }

    private var generalSection: some View {
        @Bindable var state = state
        return section("General") {
            row(title: "Your name", subtitle: state.userName.isEmpty
                ? "Add your name and Fortify greets you with it."
                : "Fortify greets you as \(state.userName).") {
                TextField("Your name", text: $state.userName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { state.userName = state.userName.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            divider
            row(title: "Appearance", subtitle: appearanceSubtitle) {
                Picker("Appearance", selection: $state.theme) {
                    ForEach(ThemePreference.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            divider
            row(title: "Start at login", subtitle: loginMessage ?? "Your apps are locked from the moment you sign in.") {
                Toggle("Start at login", isOn: $startAtLogin)
                    .labelsHidden()
                    .toggleStyle(GreenToggleStyle())
            }
            divider
            row(title: "Menu bar icon", subtitle: "Open \(AppInfo.name) or lock all apps from the menu bar.") {
                Toggle("Menu bar icon", isOn: $state.showMenuBarIcon)
                    .labelsHidden()
                    .toggleStyle(GreenToggleStyle())
            }
        }
    }

    private var quitFooter: some View {
        HStack(spacing: 12) {
            Text("Locked apps aren't protected while \(AppInfo.name) is closed.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Button("Quit \(AppInfo.name)", role: .destructive) { state.quit() }
                .buttonStyle(OutlineButtonStyle(foreground: Palette.danger))
                .font(Typo.bodyMedium)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Text

    private var touchIDSubtitle: String {
        switch touchID {
        case .ready:
            "Unlock with your fingerprint. Your PIN always works too."
        case .unavailableNow:
            "Can't be used right now (for example, the lid is closed). Your PIN works instead."
        case .notEnrolled:
            "Add a fingerprint in System Settings → Touch ID & Password first."
        case .unsupported:
            "This Mac doesn't have Touch ID. Your PIN is used instead."
        }
    }

    private var shortcutSubtitle: String {
        if let shortcutMessage { return shortcutMessage }
        guard let shortcut = state.store.lockShortcut else {
            return "Off. Click to choose one."
        }
        if state.store.lockShortcutRefused {
            return "Another app is using \(shortcut.display). Click to choose another."
        }
        return "Locks the app you're in and takes you back to the one before."
    }

    private var appearanceSubtitle: String {
        switch state.theme {
        case .system: "Matches your Mac's light or dark setting."
        case .light: "Always light, whatever your Mac uses."
        case .dark: "Always dark, whatever your Mac uses."
        }
    }

    private func refreshLoginMessage() {
        loginMessage = LoginItem.needsApproval
            ? "Approve \(AppInfo.name) in System Settings → General → Login Items."
            : nil
    }

    // MARK: - Layout

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .card()
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.border).frame(height: 1).padding(.leading, 18)
    }

    private func row<Accessory: View>(
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typo.bodyMedium)
                Text(subtitle)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            accessory()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

#Preview("Settings · Light") {
    SettingsView()
        .environment(AppState.preview(.unlocked))
        .preferredColorScheme(.light)
}

#Preview("Settings · Dark") {
    SettingsView()
        .environment(AppState.preview(.unlocked))
        .preferredColorScheme(.dark)
}
