import AppKit
import Carbon.HIToolbox
import DrevoCore

/// A button that records the next keystroke: click it, then press the keys. A bare Esc or
/// focus moving away stops recording and leaves things as they were. While recording it
/// takes every key, Tab and Space included, before the main menu sees it.
@MainActor
class KeyRecorderButton: NSButton {
    /// The title while not recording.
    var restingTitle = "" { didSet { refreshTitle() } }
    var recordingTitle = "Press keys…" { didSet { refreshTitle() } }
    /// A keystroke while recording: true when it was taken (recording ends), false to
    /// keep listening for another.
    var onKeystroke: ((NSEvent) -> Bool)?
    /// Recording ended, however it ended.
    var onEnd: (() -> Void)?
    private(set) var isRecording = false {
        didSet {
            refreshTitle()
            if oldValue, !isRecording { onEnd?() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording(_:))
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func refreshTitle() {
        title = isRecording ? recordingTitle : restingTitle
        bezelColor = isRecording ? .controlAccentColor : nil
    }

    @objc func toggleRecording(_ sender: Any?) {
        isRecording.toggle()
        if isRecording { window?.makeFirstResponder(self) }
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    /// ⌘ and ⌃ combos and F-keys arrive as key equivalents before any keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape), KeyCombo.Modifiers(event.modifierFlags).isEmpty {
            isRecording = false
            return
        }
        if onKeystroke?(event) == true { isRecording = false }
    }
}
