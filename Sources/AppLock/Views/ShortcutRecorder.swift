import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Shows a shortcut; click it, then press the new one. Esc cancels, Delete
/// turns it off. Combinations that would swallow typing aren't taken.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyCombo?
    /// What to tell the user while recording (nil when idle).
    @Binding var message: String?
    /// Recording started or ended.
    var onRecording: (Bool) -> Void = { _ in }

    @State private var recording = false
    @State private var monitor: Any?

    private static let prompt = "Press the new shortcut. Esc cancels, Delete turns it off."

    var body: some View {
        Button(recording ? "Type shortcut…" : (shortcut?.display ?? "Off")) {
            if recording { stop() } else { start() }
        }
        .buttonStyle(OutlineButtonStyle())
        .font(Typo.bodyMedium)
        .accessibilityLabel(recording ? "Recording shortcut" : "Lock shortcut \(shortcut?.display ?? "off")")
        .onDisappear(perform: stop)
    }

    private func start() {
        guard !recording else { return }
        recording = true
        message = Self.prompt
        onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only a Bool crosses the actor boundary; NSEvent isn't Sendable.
            let consumed = MainActor.assumeIsolated { handle(event) }
            return consumed ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        message = nil
        onRecording(false)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyCombo.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }

        let keyCode = Int(event.keyCode)
        if modifiers.isEmpty, keyCode == kVK_Escape {
            stop()
            return true
        }
        if modifiers.isEmpty, keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            shortcut = nil
            stop()
            return true
        }
        if let problem = KeyCombo.problem(keyCode: UInt32(keyCode), modifiers: modifiers) {
            message = problem
            return true
        }
        shortcut = KeyCombo(keyCode: UInt32(keyCode), modifiers: modifiers, key: Self.keyName(event))
        stop()
        return true
    }

    /// The key's label: its character in the current layout, or a name for keys without one.
    private static func keyName(_ event: NSEvent) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = named[Int(event.keyCode)] { return name }
        // Unshifted, so ⇧1 reads "1", not "!".
        let character = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "?"
        return character.uppercased()
    }
}
