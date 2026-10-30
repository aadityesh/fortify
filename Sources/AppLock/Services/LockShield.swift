import AppKit

/// Opaque panels over every display, put up the moment a locked app is opened
/// so none of it is ever seen, whether it's in full screen, minimized or behind
/// other windows.
///
/// They're built ahead of time: showing them is a single reorder, not building
/// a window, so they're on screen within a frame of macOS reporting the app.
/// They sit above app windows, the menu bar and the Dock, below the lock card.
/// They never take keyboard focus or capture input: ⌘Tab and the card keep
/// working, and a click on one asks for the PIN. `LockGuard` decides when they
/// come down.
@MainActor
final class LockShield {
    var onClick: () -> Void = {}

    private var panels: [ShieldPanel] = []
    private var screenObserver: NSObjectProtocol?
    private(set) var isUp = false
    /// Bumped by every show and hide; a fade-out that's been overtaken is dropped.
    private var generation = 0
    private var shownPID: pid_t?
    private var content: (name: String, icon: NSImage?) = ("", nil)

    /// Above app windows, the menu bar and the Dock; below the lock card and the
    /// Mac password dialog of Forgot PIN (coreautha, at the screen-saver level).
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

    init() {
        build()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    /// Covers every display at once.
    func show(for app: NSRunningApplication) {
        generation += 1
        if shownPID != app.processIdentifier {
            shownPID = app.processIdentifier
            content = (app.localizedName ?? "This app", app.icon)
            for panel in panels { panel.shieldView.update(name: content.name, icon: content.icon) }
        }
        for panel in panels {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        // AppKit sends window changes to WindowServer when the run loop pass
        // ends, after the card has been built (~40ms). Send them now.
        CATransaction.flush()
        if !isUp {
            isUp = true
            lockLog.notice("Shield up for \(app.bundleIdentifier ?? "?", privacy: .public)")
        }
    }

    /// Fades out, so an app that was just unlocked appears smoothly.
    func hide() {
        guard isUp else { return }
        isUp = false
        generation += 1
        let generation = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            for panel in panels { panel.animator().alphaValue = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.generation == generation else { return }
            for panel in self.panels { panel.orderOut(nil) }
        }
        lockLog.notice("Shield down")
    }

    /// WindowServer is drawing it: some of it is visible on the current Space.
    var isDrawn: Bool {
        isUp && panels.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    private func build() {
        panels = NSScreen.screens.map { screen in
            let panel = ShieldPanel(screen: screen) { [weak self] in self?.onClick() }
            panel.shieldView.update(name: content.name, icon: content.icon)
            // Order in once, invisibly, so WindowServer already has the window
            // and its backing store when it's needed for real.
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.orderOut(nil)
            panel.alphaValue = 1
            return panel
        }
    }

    private func rebuild() {
        for panel in panels { panel.orderOut(nil) }
        build()
        if isUp {
            for panel in panels { panel.orderFrontRegardless() }
        }
    }
}

private final class ShieldPanel: NSPanel {
    let shieldView: ShieldView
    private let onClick: () -> Void

    init(screen: NSScreen, onClick: @escaping () -> Void) {
        self.onClick = onClick
        shieldView = ShieldView()
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = true
        backgroundColor = ShieldView.background
        hasShadow = false
        level = LockShield.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = shieldView
        shieldView.onClick = onClick
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Over the menu bar too.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }
}

/// The locked surface, shared with the covers on full-screen Spaces so moving
/// between them looks like one continuous screen.
final class ShieldView: NSView {
    /// The app's background (paper in light, charcoal in dark), so the
    /// card and the window read as the same surface.
    static let background = NSColor.adaptive(light: 0xF4F3EE, dark: 0x0A0C0A)
    static let primaryText = NSColor.adaptive(light: 0x111411, dark: 0xF2F4EF)
    static let secondaryText = NSColor.adaptive(light: 0x6B6F68, dark: 0x8A918A)

    var onClick: () -> Void = {}
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "Unlock it above · esc to cancel")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = Self.primaryText
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = Self.secondaryText
        for view in [icon, title, subtitle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -36),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 18),
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            subtitle.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // A layer's color is fixed once set, so it's set again when light / dark changes.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Self.background.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func update(name: String, icon image: NSImage?) {
        icon.image = image ?? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        title.stringValue = name.isEmpty ? "Locked" : "\(name) is locked"
    }

    // Fortify My Mac isn't active when the shield is clicked; the first click must count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }
}
