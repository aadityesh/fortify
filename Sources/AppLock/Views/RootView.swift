import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            switch state.phase {
            case .setup:
                SetupPinView()
                    .transition(.opacity)
            case .permissions:
                PermissionStepView()
                    .transition(.opacity)
            case .locked:
                UnlockView()
                    .transition(.opacity)
            case .resetPIN:
                ResetPinView()
                    .transition(.opacity)
            case .unlocked:
                AppListView()
                    .transition(.opacity)
            }
        }
        .foregroundStyle(Palette.textPrimary)
        .frame(minWidth: 600, minHeight: 560)
        .animation(.easeInOut(duration: 0.25), value: state.phase)
    }
}
