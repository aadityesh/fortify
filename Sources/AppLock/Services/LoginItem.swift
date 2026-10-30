import ServiceManagement

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    static var needsApproval: Bool { status == .requiresApproval }

    /// Re-registers so the login item launches this copy of the app.
    static func refresh() {
        try? SMAppService.mainApp.register()
    }

    /// Returns an error message on failure.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if status != .enabled { try SMAppService.mainApp.register() }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
