# Architecture

Fortify: App Lock is a menu bar app written in Swift with SwiftUI and AppKit. It
needs the Accessibility permission and nothing else.

## Runtime map

| Type | Job |
|---|---|
| `AppDelegate` | Starts the app, builds the window and menus, starts `AppMonitor`. |
| `AppState` | What the main window shows (setup, permission, locked, unlocked) and app-wide preferences such as appearance. |
| `LockStore` | Saved settings: locked bundle IDs, PIN hash, Touch ID, relock options, lock shortcut. |
| `AppMonitor` | Listens to `NSWorkspace` (launch, activate, hide, quit, Space, sleep, screen lock), decides when to ask for the PIN, and tracks which apps were unlocked this session. |
| `LockGuard` | The lock itself: keeps every locked app hidden, and covers windows of apps that won't hide or are in full screen. |
| `LockShield` | Prebuilt opaque panels over every display, raised the instant a locked app opens so none of it is ever seen. |
| `NotchPanelController`, `NotchLockView` | The lock card under the notch: Touch ID, PIN entry, Forgot PIN, focus recovery. |
| `PresenceWatcher` | Tells when an unlocked app is minimized, hidden, closed or left on another Space, from Accessibility notifications backed by a 1 s poll. |
| `GlobalHotKey`, `KeyCombo` | The system-wide lock shortcut (Carbon hot keys, no permission needed). |
| `LockPolicy`, `PresencePolicy`, `PinHasher`, `KeyCombo`, `TripleTapDetector` | Pure logic with no AppKit, covered by `swift test`. |

## Lock-flow rules

- A locked app is kept hidden by `LockGuard` whether or not a card is up.
- Opening a locked app raises the shield over every display first, before
  anything slower, so its content never shows while the card comes up.
- Nothing captures system-wide input. If the card fails to draw, ⌘Tab still
  gets the user out, and the shield only stays while a card is up, so the Mac
  can never be left stuck.
- A PIN is accepted only while the card is settled and on screen.
- With "Relock when I leave an app" off, the presence watch still runs, so the
  full-screen timeout can relock an app parked on another Space.
- When changing `AppMonitor`, `PresenceWatcher`, `LockGuard` or
  `NotchPanelController`, check both the notification-driven path and the
  timer fallback. Unit tests don't prove real Space, window or panel behaviour.

## PIN and local security

- PINs are stored as salted PBKDF2-HMAC-SHA256 hashes. An older plain SHA-256
  hash is upgraded after its next successful unlock.
- Wrong PINs get an increasing delay for the current run of the app.
- The PIN is a convenience lock against other people using the Mac. It doesn't
  stop someone signed in to the same macOS account from changing the app or
  its data.
- The bundle identifier is `com.aadi.applock`. Changing it would lose existing
  settings, the login item and the Accessibility permission, so it needs a
  migration.

## Tests

`Package.swift` builds only the pure files under `Sources/AppLock/Services`
into a `PresencePolicy` module so `swift test` runs without the app. The Xcode
project builds the full app. Both use the same sources.
