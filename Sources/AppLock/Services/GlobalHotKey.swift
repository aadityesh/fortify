import AppKit
import Carbon.HIToolbox

/// One system-wide keyboard shortcut. Carbon's hot keys need no permission and
/// take the key press before the app in front sees it.
@MainActor
final class GlobalHotKey {
    var onPress: () -> Void = {}

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Replaces the current shortcut; nil turns it off. False if macOS refused it.
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        unregister()
        guard let combo else { return true }
        installHandler()
        // 'FMML': Fortify Lock.
        let id = EventHotKeyID(signature: 0x464D_4D4C, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetEventDispatcherTarget(), 0, &hotKey)
        guard status == noErr else {
            lockLog.error("Couldn't register the lock shortcut \(combo.display, privacy: .public): \(status)")
            hotKey = nil
            return false
        }
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onPress()
            }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
