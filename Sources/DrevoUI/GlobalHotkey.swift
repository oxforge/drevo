import AppKit
import Carbon.HIToolbox
import DrevoCore

/// The shortcut chosen in Settings: the combo for showing and checking it, and the key
/// code it was typed with, which is what the system registers (a combo names a
/// character, and which key types it depends on the keyboard layout).
struct HotkeySetting: Codable, Equatable {
    var combo: KeyCombo
    var keyCode: UInt16
}

/// A system-wide shortcut that brings Drevo to the front. Registered with the Carbon
/// hot-key API: it needs no Accessibility permission, unlike a global event monitor.
@MainActor
final class GlobalHotkey {
    var onPress: (() -> Void)?
    private(set) var registered: HotkeySetting?
    /// The last setting couldn't be registered: another app holds the shortcut.
    private(set) var isRefused = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4452_5645 // "DRVE"

    static func carbonModifiers(_ modifiers: KeyCombo.Modifiers) -> UInt32 {
        var m = 0
        if modifiers.contains(.command) { m |= cmdKey }
        if modifiers.contains(.option) { m |= optionKey }
        if modifiers.contains(.control) { m |= controlKey }
        if modifiers.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }

    /// Replaces the registered shortcut; nil turns it off. False if the system refused.
    @discardableResult
    func register(_ setting: HotkeySetting?) -> Bool {
        unregister()
        isRefused = false
        guard let setting else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(setting.keyCode), Self.carbonModifiers(setting.combo.modifiers),
                                         EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            isRefused = true
            return false
        }
        hotKey = ref
        registered = setting
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registered = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Carbon delivers hot-key events on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotkey.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

/// Settings' button for choosing the global shortcut: click, then press the keys.
/// Esc leaves it as it was.
@MainActor
final class HotkeyRecorderButton: KeyRecorderButton {
    /// The shortcut shown while not recording.
    var setting: HotkeySetting? { didSet { restingTitle = setting?.combo.description ?? "Record Shortcut" } }
    /// A shortcut was typed; return why it can't be used, or nil when it was taken.
    var onRecord: ((HotkeySetting) -> String?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        restingTitle = "Record Shortcut"
        recordingTitle = "Press a shortcut…"
        onKeystroke = { [weak self] event in
            guard let combo = KeyCombo.candidates(for: event).first else {
                NSSound.beep()
                return false
            }
            // A refused shortcut leaves the button waiting for another one.
            return self?.onRecord?(HotkeySetting(combo: combo, keyCode: event.keyCode)) == nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
