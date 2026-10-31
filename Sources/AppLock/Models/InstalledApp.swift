import Foundation

struct InstalledApp: Identifiable, Hashable {
    /// Bundle identifier.
    let id: String
    let name: String
    let url: URL
    /// Where the app list files it unless the user moves it.
    var automaticCategory: AppCategory = .other
}
