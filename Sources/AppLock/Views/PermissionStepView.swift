import SwiftUI

/// Onboarding step: ask for Accessibility, which AppLock needs to reliably hide
/// locked apps. Moves on by itself as soon as the permission is granted.
struct PermissionStepView: View {
    @Environment(AppState.self) private var state
    @State private var requested = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Palette.onAccent)
                .frame(width: 52, height: 52)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(spacing: 8) {
                Text("Let Fortify hide locked apps")
                    .font(Typo.display(34))
                    .multilineTextAlignment(.center)
                Text("macOS only lets an app hide other apps with Accessibility access. Fortify uses it for one thing: keeping a locked app out of sight until you unlock it.")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                step(1, "Click **Allow Accessibility** below.")
                divider
                step(2, "In the macOS prompt, click **Open System Settings**.")
                divider
                step(3, "Turn on **\(AppInfo.name)**, then come back. You'll continue automatically.")
            }
            .card(radius: 12)

            VStack(spacing: 12) {
                Button {
                    requested = true
                    // Only the macOS prompt; its "Open System Settings" button takes it from there.
                    AppHider.requestAccessibility()
                } label: {
                    Text("Allow Accessibility").font(Typo.bodyMedium)
                }
                .buttonStyle(PillButtonStyle())

                if requested {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for permission…")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .transition(.opacity)
                }

                if requested {
                    HStack(spacing: 4) {
                        Text("No prompt?")
                            .foregroundStyle(Palette.textSecondary)
                        Button("Open Accessibility settings") { AppHider.openAccessibilitySettings() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.textPrimary)
                            .underline()
                    }
                    .font(Typo.caption)

                    HStack(spacing: 4) {
                        Text("Already turned on?")
                            .foregroundStyle(Palette.textSecondary)
                        Button("Reset permission") { AppHider.resetAccessibility() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.textPrimary)
                            .underline()
                    }
                    .font(Typo.caption)
                    .help("Clears an old \(AppInfo.name) entry in System Settings and asks again. Then turn \(AppInfo.name) on once more.")
                }
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            ThemeToggle()
                .padding(EdgeInsets(top: 38, leading: 0, bottom: 0, trailing: 18))
        }
        .animation(.easeOut(duration: 0.2), value: requested)
        .task {
            guard !isRunningForPreviews else { return }
            while !Task.isCancelled {
                if AppHider.hasAccessibility {
                    state.phase = .unlocked
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.border).frame(height: 1).padding(.leading, 50)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.positiveText)
                .frame(width: 22, height: 22)
                .background(Palette.positiveFill, in: Circle())
            Text(text)
                .font(Typo.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

#Preview("Permission · Light") {
    PermissionStepView()
        .environment(AppState.preview(.permissions))
        .frame(width: 760, height: 680)
        .background(Palette.background)
        .preferredColorScheme(.light)
}

#Preview("Permission · Dark") {
    PermissionStepView()
        .environment(AppState.preview(.permissions))
        .frame(width: 760, height: 680)
        .background(Palette.background)
        .preferredColorScheme(.dark)
}
