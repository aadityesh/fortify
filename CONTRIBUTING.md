# Contributing to Fortify: App Lock

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

[Open an issue](https://github.com/aadityesh/fortify/issues/new/choose) with
your macOS version, the Fortify version (Fortify: App Lock → About), the app you
locked, and the steps that show the problem. Lock bugs often depend on how the
app was open (full screen, another desktop, minimized), so say that too.

Logs help a lot. Reproduce the problem, then run:

```sh
/usr/bin/log show --last 5m --style compact --predicate 'subsystem == "com.aadi.applock"'
```

Found a way to get into a locked app without the PIN? Please report it
privately instead; see [SECURITY.md](SECURITY.md).

## Building

You need macOS 14 or later and Xcode 16 or later.

```sh
./scripts/install.sh   # build a Release copy, install it in /Applications and open it
swift test             # unit tests
```

Or open `AppLock.xcodeproj` and run the **AppLock** scheme. If Xcode's command
line tools point somewhere else, prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

The scripts sign with your Developer ID or Apple Development certificate if
you have one, and ad hoc otherwise. With ad hoc signing, macOS asks for the
Accessibility permission again after every rebuild; remove the old entry in
System Settings → Privacy & Security → Accessibility if it gets confused.

## Making a change

1. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), especially the lock-flow
   rules. The lock must never leave the Mac stuck or show a locked app.
2. Keep decisions that can be tested free of AppKit, in `LockPolicy`,
   `PresencePolicy` or a similar type, and add tests in `Tests/`.
3. Match the code around you: small types, short comments that say why, and
   plain words in the UI.
4. Test by hand what the unit tests can't: a full-screen app, a second
   desktop, minimized and closed windows, a second display if you have one,
   and both light and dark appearance.
5. Open a pull request describing what changed and how you tested it.

By contributing you agree that your work is released under the
[MIT License](LICENSE), and to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Releasing (maintainers)

1. Bump `MARKETING_VERSION` in the Xcode project and add the changes to
   [CHANGELOG.md](CHANGELOG.md).
2. Run `./scripts/make-dmg.sh`. With a Developer ID certificate it also
   notarizes and staples the DMG; this needs notarytool credentials saved once
   (see the comment at the top of the script).
3. Create a GitHub release tagged `v<version>` and attach the DMG.
