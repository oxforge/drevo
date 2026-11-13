import AppKit
import Carbon.HIToolbox
import Testing
@testable import DrevoCore
@testable import DrevoUI

/// The global shortcut's setting, recorder and what pressing it does. Nothing here
/// registers a real system-wide hotkey.
@MainActor
@Suite(.serialized) struct GlobalHotkeyTests {
    let fx = Fixture()

    func setting(_ keys: String, keyCode: UInt16) -> HotkeySetting {
        HotkeySetting(combo: try! KeyCombo(parsing: keys), keyCode: keyCode)
    }

    @Test func carbonModifiersMatchTheCombo() {
        #expect(GlobalHotkey.carbonModifiers([.command, .option]) == UInt32(cmdKey | optionKey))
        #expect(GlobalHotkey.carbonModifiers([.control, .shift]) == UInt32(controlKey | shiftKey))
    }

    @Test func settingsRefuseShortcutsTheRuleRejects() {
        let env = testEnvironment(trash: fx.url.appendingPathComponent("trash"))
        let model = SettingsModel(env: env)
        #expect(env.preferences.globalHotkey == nil, "off by default")
        #expect(model.setGlobalHotkey(setting("cmd+space", keyCode: 49))?.contains("macOS") == true)
        #expect(env.preferences.globalHotkey == nil)
        // ⌘D is Duplicate inside Drevo.
        #expect(model.setGlobalHotkey(setting("cmd+d", keyCode: 2))?.contains("Duplicate") == true)
        #expect(model.setGlobalHotkey(setting("ctrl+opt+cmd+d", keyCode: 2)) == nil)
        #expect(env.preferences.globalHotkey == setting("ctrl+opt+cmd+d", keyCode: 2), "saved, key code and all")
        model.setGlobalHotkey(nil)
        #expect(env.preferences.globalHotkey == nil)
    }

    @Test func recorderTakesTheTypedShortcut() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        let button = HotkeyRecorderButton(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
        window.contentView!.addSubview(button)
        var recorded: [HotkeySetting] = []
        var answer: String?
        button.onRecord = { recorded.append($0); return answer }
        #expect(button.title == "Record Shortcut")

        // Keys do nothing until the button is clicked.
        #expect(!button.performKeyEquivalent(with: key(2, "d", [.command, .control], window: window)))
        button.toggleRecording(nil)
        #expect(button.title == "Press a shortcut…")

        // A refused shortcut keeps it waiting; Esc gives up.
        answer = "no"
        #expect(button.performKeyEquivalent(with: key(49, " ", [.command], window: window)))
        #expect(button.isRecording)
        button.keyDown(with: key(53, "\u{1b}", window: window))
        #expect(!button.isRecording)

        answer = nil
        button.toggleRecording(nil)
        #expect(button.performKeyEquivalent(with: key(2, "d", [.command, .control], window: window)))
        #expect(!button.isRecording)
        #expect(recorded.last == setting("ctrl+cmd+d", keyCode: 2))
        button.setting = recorded.last
        #expect(button.title == "⌃⌘D")
    }

    @Test func pressingItOpensAWindowWhenThereIsNone() {
        let env = testEnvironment(trash: fx.url.appendingPathComponent("trash"))
        let delegate = AppDelegate(options: LaunchOptions(arguments: ["drevo", "--ephemeral", fx.url.path]))
        delegate.useEnvironmentForTests(env)
        var activated = 0
        delegate.activateApp = { activated += 1 }

        delegate.showFromHotkey()
        #expect(activated == 1)
        #expect(delegate.windowControllers.count == 1)
        let window = delegate.windowControllers[0].window!

        // With a window it comes forward; no second one opens.
        window.orderOut(nil)
        delegate.showFromHotkey()
        #expect(delegate.windowControllers.count == 1)
        #expect(window.isVisible)
        window.close()
    }
}
