<p align="center">
  <img src="Resources/Brand/fortify-logo-v2.png" width="128" alt="Fortify My Mac icon">
</p>

<h1 align="center">Fortify My Mac</h1>

<p align="center">
  Lock any app on your Mac behind Touch ID or a PIN.<br>
  Free, open source, and nothing ever leaves your Mac.
</p>

<p align="center">
  <a href="https://github.com/aadityesh/fortify/releases/latest"><img src="https://img.shields.io/github/v/release/aadityesh/fortify?label=download" alt="Latest release"></a>
  <a href="https://github.com/aadityesh/fortify/actions/workflows/tests.yml"><img src="https://github.com/aadityesh/fortify/actions/workflows/tests.yml/badge.svg" alt="Tests"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14 or later">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/aadityesh/fortify" alt="MIT License"></a>
</p>

---

Lend someone your Mac without them opening your messages, mail or browser.
Pick the apps to protect; opening one brings up a lock card from the notch,
and the app stays hidden until you unlock it with Touch ID or your PIN.

## Features

- **Lock any app**: chat apps, mail, browsers, notes, System Settings, and web
  apps installed from Chrome, Brave, Edge or Safari.
- **Touch ID or PIN**: a 4 or 6 digit PIN always works, even with the lid closed.
- **Nothing shows through**: the screen is covered the moment a locked app
  opens, including apps in full screen or on another desktop.
- **Relocks on its own**: when you minimize, hide or close an unlocked app,
  when your Mac sleeps, or when the screen locks.
- **Lock shortcut**: press <kbd>⌃</kbd><kbd>⌘</kbd><kbd>L</kbd> in an
  unlocked app to lock it straight away and go back to the app you were in.
  Change it or turn it off in Settings.
- **Lock All** from the menu bar.
- **Forgot your PIN?** Confirm with your Mac password and choose a new one.
- **Light and dark**: follows your Mac, or pick one in Settings.

## Download

1. Download **Fortify-My-Mac-&lt;version&gt;.dmg** from the
   [latest release](https://github.com/aadityesh/fortify/releases/latest).
2. Open it and drag **Fortify My Mac** into **Applications**.
3. Open Fortify My Mac from Applications. The first time, macOS says it
   "could not verify" the app. That's because the app isn't notarized with
   Apple (that needs a paid Apple developer account), not because anything is
   wrong with it. To open it anyway:
   - Click **Done**, then open **System Settings → Privacy & Security**.
   - Scroll down to "Fortify My Mac was blocked" and click **Open Anyway**.
   - Confirm with your Mac password. You only need to do this once.

   Prefer Terminal? This does the same thing:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Fortify My Mac.app"
   ```
4. Create your PIN and allow **Accessibility** when asked (see below for why).

Not sure about running a download? [Build it yourself](#build-from-source)
from the source in this repo instead.

**Requirements:** macOS 14 Sonoma or later, on Apple silicon or Intel. Touch ID
is optional.

## Privacy

- **No network access.** No account, no analytics, no telemetry, no update
  checks. Fortify never connects to the internet.
- **Your PIN is never stored.** Only a salted PBKDF2-SHA256 hash is kept, in the
  app's preferences on your Mac.
- **Accessibility permission** lets Fortify hide locked apps and notice when an
  unlocked one is minimized or closed. It looks at which windows are open, not
  what's in them.
- **Notifications** are only used for the "‹App› locked" banner after the lock
  shortcut.

## What it does and doesn't protect against

Fortify is a privacy lock for when someone else is using your Mac: a friend,
a colleague, a child. It keeps them out of the apps you choose.

It is not encryption. Someone signed in to your macOS account with enough time
and know-how can force-quit Fortify or read app data from disk. To protect your
data itself, use [FileVault](https://support.apple.com/guide/mac-help/mh11785)
and give other people their own user account.

## Build from source

You need Xcode 16 or later.

```sh
git clone https://github.com/aadityesh/fortify.git
cd fortify
./scripts/install.sh      # builds a Release copy, installs it in /Applications and opens it
```

Or open `AppLock.xcodeproj` in Xcode and run the **AppLock** scheme. Without an
Apple developer certificate the scripts sign the app ad hoc, which works fine;
macOS then asks for the Accessibility permission again after each rebuild.

| Command | What it does |
|---|---|
| `./scripts/install.sh` | Build, install into /Applications, and open |
| `./scripts/make-dmg.sh` | Build `build/Fortify-My-Mac-<version>.dmg` for a release |
| `swift test` | Run the unit tests |

How the app is put together: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Contributing

Bug reports, ideas and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) to get started, and
[SECURITY.md](SECURITY.md) for reporting a way around the lock privately.

## License

[MIT](LICENSE) © 2026 Aadityesh Jain
