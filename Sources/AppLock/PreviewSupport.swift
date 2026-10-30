import AppKit

/// True while Xcode renders SwiftUI previews (used to skip Touch ID prompts there).
let isRunningForPreviews = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

extension AppState {
    /// A state for previews, already in the given phase and with the app list loaded.
    @MainActor
    static func preview(_ phase: Phase) -> AppState {
        let state = AppState()
        state.phase = phase
        state.catalog.reload()
        return state
    }
}

extension NotchModel {
    @MainActor
    static func preview(entered: String = "", message: String? = nil) -> NotchModel {
        let model = NotchModel()
        model.expanded = true
        model.visible = true
        model.appName = "Calendar"
        model.icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Calendar.app")
        model.pinLength = 6
        model.entered = entered
        model.message = message
        model.biometricsAvailable = true
        model.notchSize = CGSize(width: 185, height: 32)
        model.expandedSize = CGSize(width: 390, height: 200)
        return model
    }
}
