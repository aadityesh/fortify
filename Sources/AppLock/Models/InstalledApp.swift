import Foundation

struct InstalledApp: Identifiable, Hashable {
    /// Bundle identifier.
    let id: String
    let name: String
    let url: URL
}
