import AppKit
import SwiftUI

@main
@MainActor
enum AppLockMain {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let state = AppState()
    private var monitor: AppMonitor?
    private var window: NSWindow?
    private var slashMonitor: Any?
    private var statusItem: NSStatusItem?
    private var launchedAsLoginItem = false

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Only readable while the launch Apple Event is being handled.
        launchedAsLoginItem = Self.detectLoginLaunch()
        NSApp.mainMenu = Self.buildMainMenu(target: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessibility calls are synchronous; the default 6s timeout would let one
        // hung app freeze Fortify (and the lock card) for seconds at a time.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        state.applyTheme()
        // The app may have moved or been renamed since start-at-login was turned on;
        // registering again points the login item at this copy.
        if state.store.hasPIN, LoginItem.isEnabled { LoginItem.refresh() }
        state.catalog.reload()

        let monitor = AppMonitor(store: state.store)
        monitor.onSessionLocked = { [weak self] in self?.state.lock(reason: "screen locked or Mac slept") }
        monitor.onWillPresentCard = { [weak self] in self?.closeWindowOnOtherSpace() }
        monitor.start()
        self.monitor = monitor

        installSlashShortcut()

        state.onMenuBarIconChange = { [weak self] show in self?.setMenuBarIcon(visible: show) }
        setMenuBarIcon(visible: state.showMenuBarIcon)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.allowQuit = true }
        }

        if state.store.hasPIN && launchedAsLoginItem {
            // Silent start: no window, no Dock icon, just guarding.
            NSApp.setActivationPolicy(.accessory)
        } else {
            showMainWindow()
        }
    }

    /// Opening AppLock again (Spotlight, Finder, Launchpad) brings the window back.
    func applicationDidBecomeActive(_ notification: Notification) {
        state.recheckAccessibility()
    }

    /// ⌘H hides the window, so it needs unlocking again.
    func applicationDidHide(_ notification: Notification) {
        state.lock(reason: "Fortify hidden")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting turns the protection off, so it needs an unlocked session.
        let unlockedAndVisible = window?.isVisible == true && (state.phase == .unlocked || state.phase == .permissions)
        if state.allowQuit || !state.store.hasPIN || unlockedAndVisible {
            return .terminateNow
        }
        state.quitAfterUnlock = true
        showMainWindow()
        return .terminateCancel
    }

    // MARK: - Window

    func showMainWindow() {
        let window = self.window ?? makeWindow()
        self.window = window

        if !window.isVisible || window.isMiniaturized { state.lock(reason: "window reopened") }

        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        state.quitAfterUnlock = false
        state.lock(reason: "window closed")
        // Disappear from the Dock and app switcher; keep running in the background.
        // Destroy the window too: a closed window still belongs to its Space, and
        // activating Fortify for a lock card would make macOS switch to that
        // Space. It's rebuilt (at the saved position) when the app is reopened.
        let closing = notification.object as? NSWindow
        DispatchQueue.main.async { [weak self] in
            NSApp.setActivationPolicy(.accessory)
            guard let self, let closing, self.window === closing, !closing.isVisible else { return }
            closing.delegate = nil
            closing.contentView = nil
            self.window = nil
        }
    }

    /// Minimizing counts as leaving: the window comes back locked.
    func windowDidMiniaturize(_ notification: Notification) {
        state.lock(reason: "window minimized")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 560)
        window.delegate = self
        window.contentView = NSHostingView(rootView: RootView().environment(state))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        return window
    }

    /// Activating Fortify for a lock card would switch to the Space our
    /// window is on; close it instead (it's locked when reopened anyway).
    private func closeWindowOnOtherSpace() {
        guard let window, window.isVisible, !window.isOnActiveSpace else { return }
        window.close()
    }

    @objc func openSettings(_ sender: Any?) {
        showMainWindow()
        state.showSettings = true
    }

    // MARK: - Menu bar icon

    private func setMenuBarIcon(visible: Bool) {
        guard visible else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarIcon()
        item.button?.toolTip = AppInfo.name

        let menu = NSMenu()
        menu.addItem(menuItem("Open \(AppInfo.name)", #selector(menuOpen)))
        menu.addItem(menuItem("Lock All Apps Now", #selector(menuLockNow)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(openSettings(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit \(AppInfo.name)…", #selector(menuQuit)))
        item.menu = menu
        statusItem = item
    }

    /// Fortify's fortress-and-keyhole mark, as a template image so the menu bar
    /// tints it for light and dark backgrounds like every other menu bar icon.
    private static func menuBarIcon() -> NSImage {
        let size = NSSize(width: 16, height: 17)
        let image = NSImage(size: size, flipped: true) { rect in
            // The mark spans x 0.2–0.8 and y 0.2–0.85 of its unit square; fit that span.
            let scale = min(rect.width / 0.6, rect.height / 0.65)
            let unit = CGRect(
                x: rect.midX - 0.5 * scale,
                y: rect.midY - 0.525 * scale,
                width: scale,
                height: scale
            )
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(FortressShape().path(in: unit).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = AppInfo.name
        return image
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuOpen() { showMainWindow() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(focusSearch(_:)):
            return canFocusSearch
        default:
            break
        }
        return true
    }

    @objc private func menuLockNow() {
        monitor?.relockAll()
        state.lock(reason: "Lock All Apps Now")
    }

    /// Quitting turns protection off, so it goes through the normal check:
    /// it works while AppLock is unlocked, otherwise it opens the unlock screen.
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - "/" focuses search

    private func installSlashShortcut() {
        slashMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only a Bool crosses the actor boundary; NSEvent isn't Sendable.
            let consumed = MainActor.assumeIsolated { self?.handleSlash(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func handleSlash(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers == "/",
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let window, event.window === window,
              canFocusSearch,
              !(window.firstResponder is NSText) else { return false }
        state.searchFocusToken += 1
        return true
    }

    /// The app list is on screen with no sheet over it.
    private var canFocusSearch: Bool {
        window?.isKeyWindow == true && state.phase == .unlocked && !state.showSettings
    }

    /// Edit ▸ Find… (⌘F), the standard way in alongside "/".
    @objc func focusSearch(_ sender: Any?) {
        guard canFocusSearch else { return }
        state.searchFocusToken += 1
    }

    // MARK: - Helpers

    private static func detectLoginLaunch() -> Bool {
        if ProcessInfo.processInfo.arguments.contains("--background") { return true }
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        // Do not infer a login launch from Finder's launch time: a normal manual
        // launch soon after sign-in must still show the app window.
        return false
    }

    private static func buildMainMenu(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(AppInfo.name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(AppInfo.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = edit.addItem(withTitle: "Find…", action: #selector(AppDelegate.focusSearch(_:)), keyEquivalent: "f")
        find.target = target
        main.addItem(submenu(edit))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(windowMenu))
        NSApp.windowsMenu = windowMenu

        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
