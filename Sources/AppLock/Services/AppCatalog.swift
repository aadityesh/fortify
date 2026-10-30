import AppKit
import Observation

/// Finds every installed .app bundle the user could reasonably want to lock.
@MainActor
@Observable
final class AppCatalog {
    private(set) var apps: [InstalledApp] = []
    private(set) var isLoading = false

    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var lastScan = Date.distantPast

    /// Apps that must never be lockable: ourselves (we'd lock the user out) and Finder.
    nonisolated static let excludedIDs: Set<String> = [
        Bundle.main.bundleIdentifier ?? "com.aadi.applock",
        "com.apple.finder",
        "com.apple.loginwindow",
    ]

    /// Rescans in the background, keeping the current list on screen meanwhile.
    /// Called at launch and whenever the list shows or the app comes back, so a
    /// scan already running, or one from the last few seconds, is reused.
    func reload() {
        guard !isLoading, Date().timeIntervalSince(lastScan) > 5 else { return }
        isLoading = true
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { AppCatalog.scan() }.value
            guard let self else { return }
            // Same apps: leave the list alone so nothing redraws.
            if found != self.apps { self.apps = found }
            self.lastScan = Date()
            self.isLoading = false
        }
    }

    func icon(for app: InstalledApp) -> NSImage {
        if let cached = iconCache[app.id] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        iconCache[app.id] = icon
        return icon
    }

    nonisolated static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]

        var byID: [String: InstalledApp] = [:]

        func visit(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for item in items {
                if item.pathExtension == "app" {
                    guard let bundle = Bundle(url: item),
                          let id = bundle.bundleIdentifier,
                          !excludedIDs.contains(id),
                          byID[id] == nil else { continue }
                    let name = (fm.displayName(atPath: item.path) as NSString).deletingPathExtension
                    byID[id] = InstalledApp(id: id, name: name, url: item)
                } else if depth < 2,
                          (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    // e.g. /Applications/Utilities, vendor folders like /Applications/Adobe …
                    visit(item, depth: depth + 1)
                }
            }
        }

        roots.forEach { visit($0, depth: 0) }
        return byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
