import Foundation

enum AppInfo {
    /// The name macOS shows for the app (menu bar, Dock, System Settings).
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Fortify: App Lock"
}
