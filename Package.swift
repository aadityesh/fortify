// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppLockPresenceTests",
    platforms: [.macOS(.v14)],
    products: [],
    targets: [
        .target(
            name: "PresencePolicy",
            path: "Sources/AppLock/Services",
            exclude: [
                "AppCatalog.swift", "AppHider.swift", "AppMonitor.swift",
                "Authenticator.swift", "LockStore.swift", "LoginItem.swift",
                "PresenceWatcher.swift",
            ],
            sources: ["PresencePolicy.swift", "PinHasher.swift", "LockPolicy.swift", "TripleTapDetector.swift", "KeyCombo.swift", "AppCategory.swift"]
        ),
        .testTarget(
            name: "PresencePolicyTests",
            dependencies: ["PresencePolicy"],
            path: "Tests/PresencePolicyTests"
        ),
    ]
)
