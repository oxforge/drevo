import AppKit
import DrevoCore
import SwiftUI

/// Settings ▸ Keys: every command's keys, changed by pressing them. `KeyRecording` decides
/// what a keystroke does; `AppEnvironment` saves to keybindings.json and reloads.
@MainActor
final class ShortcutEditorModel: ObservableObject {
    /// The line under a command's row: a refusal, a note, or the "Use it here?" question.
    struct Notice: Equatable {
        let command: CommandID
        let message: String
        /// What "Use Here" applies; nil unless this is the question.
        let pending: [CommandID: [KeyCombo]]?
        /// The note to show after "Use Here".
        let pendingNote: String?
        let isRefusal: Bool
        var isQuestion: Bool { pending != nil }
    }

    struct Section: Identifiable {
        let category: CommandCategory
        let commands: [CommandSpec]
        var id: String { category.rawValue }
    }

    let env: AppEnvironment
    @Published var query = ""
    @Published var changedOnly = false
    @Published private(set) var notice: Notice?
    @Published private(set) var keyMap: KeyMap
    @Published private(set) var defaults: KeyMap
    /// Why keybindings.json can't be read; editing waits until it can.
    @Published private(set) var fileError: String?
    /// The keycap under the pointer, which shows its × (the toolchain has no @State).
    struct HoveredKey: Equatable { let command: CommandID; let key: KeyCombo }
    @Published private(set) var hoveredKey: HoveredKey?
    private var observer: NSObjectProtocol?

    init(env: AppEnvironment) {
        self.env = env
        keyMap = env.keyMap
        defaults = env.defaultKeyMap
        fileError = env.keyBindingsFileError
        observer = NotificationCenter.default.addObserver(forName: AppEnvironment.keyMapDidChange, object: env, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        keyMap = env.keyMap
        defaults = env.defaultKeyMap
        fileError = env.keyBindingsFileError
    }

    var canEdit: Bool { fileError == nil }

    func keys(for id: CommandID) -> [KeyCombo] { keyMap.keys(for: id) }

    func isChanged(_ id: CommandID) -> Bool { keyMap.keys(for: id) != defaults.keys(for: id) }

    var changedCount: Int { CommandRegistry.all.filter { isChanged($0.id) }.count }

    /// Commands by category in registry (menu) order, narrowed by the search and the
    /// Changed switch.
    var sections: [Section] {
        CommandCategory.allCases.compactMap { category in
            let commands = CommandRegistry.all.filter {
                $0.category == category && (!changedOnly || isChanged($0.id)) && $0.matches(query, keys: keys(for: $0.id))
            }
            return commands.isEmpty ? nil : Section(category: category, commands: commands)
        }
    }

    // MARK: Editing

    /// A keystroke recorded for `id` (its readings, most specific first). True when the
    /// recorder should stop listening; a refused key keeps it listening.
    @discardableResult
    func record(_ candidates: [KeyCombo], for id: CommandID, slot: KeyRecording.Slot) -> Bool {
        guard canEdit else { return false }
        let context = KeyRecording.Context(keyMap: keyMap, defaults: defaults,
                                           globalHotkey: env.preferences.globalHotkey?.combo,
                                           menuShortcuts: MainMenu.fixedShortcuts)
        switch KeyRecording.record(candidates, for: id, slot: slot, in: context) {
        case .unchanged:
            notice = nil
            return true
        case .refused(let message):
            notice = Notice(command: id, message: message, pending: nil, pendingNote: nil, isRefusal: true)
            return false
        case .taken(let message, let changes, let note):
            notice = Notice(command: id, message: message, pending: changes, pendingNote: note, isRefusal: false)
            return true
        case .apply(let changes, let note):
            notice = note.map { Notice(command: id, message: $0, pending: nil, pendingNote: nil, isRefusal: false) }
            save(changes)
            return true
        }
    }

    /// The answer to "Use it here instead?": the key moves.
    func useHere() {
        guard let asked = notice, let changes = asked.pending else { return }
        notice = asked.pendingNote.map { Notice(command: asked.command, message: $0, pending: nil, pendingNote: nil, isRefusal: false) }
        save(changes)
    }

    func cancelNotice() { notice = nil }

    /// The pointer entered or left a keycap. Leaving clears only that keycap's hover:
    /// the next one may have been entered first.
    func hover(_ key: HoveredKey, inside: Bool) {
        if inside { hoveredKey = key } else if hoveredKey == key { hoveredKey = nil }
    }

    /// A refusal goes away with the recording it answered.
    func recordingEnded(for id: CommandID) {
        if let notice, notice.command == id, notice.isRefusal { self.notice = nil }
    }

    func remove(_ key: KeyCombo, from id: CommandID) {
        notice = nil
        save([id: keys(for: id).filter { $0 != key }])
    }

    func reset(_ id: CommandID) {
        notice = nil
        attempt { try env.resetKeys(for: id) }
    }

    func resetAll() {
        let detail = canEdit ? "Your changes in keybindings.json are removed." : "keybindings.json can’t be read; it will be replaced."
        env.operations.prompts.confirm("Reset all shortcuts to their defaults?", detail: detail, button: "Reset", in: NSApp?.keyWindow) { [weak self] reset in
            guard reset, let self else { return }
            self.notice = nil
            self.attempt { try self.env.resetAllKeys() }
        }
    }

    func openFile() {
        NSApp.sendAction(#selector(AppDelegate.editKeyBindings(_:)), to: nil, from: nil)
    }

    private func save(_ changes: [CommandID: [KeyCombo]]) {
        attempt { try env.saveKeyChanges(changes) }
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch {
            env.operations.prompts.showError("Couldn’t save the shortcuts.", detail: error.localizedDescription, in: nil)
        }
    }
}

// MARK: - Views

struct ShortcutEditorView: View {
    @ObservedObject var editor: ShortcutEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = editor.fileError {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("keybindings.json can’t be read, so shortcuts can’t be changed here. \(error)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open keybindings.json") { editor.openFile() }.controlSize(.small)
                }
            }
            HStack {
                TextField("Search commands or keys (rename, f5, ⌘D)", text: $editor.query)
                    .textFieldStyle(.roundedBorder)
                Picker("Show", selection: $editor.changedOnly) {
                    Text("All").tag(false)
                    Text("Changed (\(editor.changedCount))").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            List {
                ForEach(editor.sections) { section in
                    Section(section.category.rawValue) {
                        ForEach(section.commands, id: \.id) { spec in
                            ShortcutRow(editor: editor, spec: spec)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Reset All…") { editor.resetAll() }
                    .disabled(editor.canEdit && editor.changedCount == 0)
                Text("Click a key to change it, + to add one, hover and × to remove.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open keybindings.json") { editor.openFile() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(16)
    }
}

private struct ShortcutRow: View {
    @ObservedObject var editor: ShortcutEditorModel
    let spec: CommandSpec

    var body: some View {
        let changed = editor.isChanged(spec.id)
        let keys = editor.keys(for: spec.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(Color.accentColor).frame(width: 5, height: 5).opacity(changed ? 1 : 0)
                Text(spec.title).fontWeight(changed ? .semibold : .regular)
                Spacer()
                if keys.isEmpty { Text("—").foregroundStyle(.tertiary) }
                ForEach(keys, id: \.self) { key in
                    Keycap(editor: editor, id: spec.id, slot: .replace(key), title: key.description)
                }
                Keycap(editor: editor, id: spec.id, slot: .add, title: "+")
                Button { editor.reset(spec.id) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Reset to the default keys")
                    .opacity(changed ? 1 : 0)
                    .disabled(!changed || !editor.canEdit)
            }
            if let notice = editor.notice, notice.command == spec.id {
                HStack(spacing: 6) {
                    Text(notice.message)
                        .font(.caption)
                        .foregroundStyle(notice.isQuestion || notice.isRefusal ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    if notice.isQuestion {
                        Button("Use Here") { editor.useHere() }.controlSize(.small)
                        Button("Cancel") { editor.cancelNotice() }.controlSize(.small)
                    }
                }
                .padding(.leading, 9)
            }
        }
        .padding(.vertical, 1)
    }
}

/// One key of a command (or the + after them): click to record; hover shows × to remove.
private struct Keycap: View {
    @ObservedObject var editor: ShortcutEditorModel
    let id: CommandID
    let slot: KeyRecording.Slot
    let title: String

    private var hovering: Bool {
        guard case .replace(let key) = slot else { return false }
        return editor.hoveredKey == ShortcutEditorModel.HoveredKey(command: id, key: key)
    }

    var body: some View {
        KeycapRecorder(title: title, enabled: editor.canEdit,
                       onKeystroke: { [editor, id, slot] event in editor.record(KeyCombo.candidates(for: event), for: id, slot: slot) },
                       onEnd: { [editor, id] in editor.recordingEnded(for: id) })
            .fixedSize()
            .help(slot == .add ? "Add a key" : "Click, then press the new key")
            .overlay(alignment: .topTrailing) {
                if case .replace(let key) = slot, hovering, editor.canEdit {
                    Button { editor.remove(key, from: id) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .offset(x: 4, y: -4)
                    .help("Remove \(title)")
                }
            }
            // The hover area reaches 4 points past the keycap, so the × (which sticks out
            // by that much) stays up while the pointer moves onto it.
            .padding(4)
            .contentShape(Rectangle())
            .onHover { inside in
                guard case .replace(let key) = slot else { return }
                editor.hover(ShortcutEditorModel.HoveredKey(command: id, key: key), inside: inside)
            }
            .padding(-4)
    }
}

private struct KeycapRecorder: NSViewRepresentable {
    let title: String
    let enabled: Bool
    let onKeystroke: (NSEvent) -> Bool
    let onEnd: () -> Void

    func makeNSView(context: Context) -> KeyRecorderButton {
        let button = KeyRecorderButton(frame: .zero)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return button
    }

    func updateNSView(_ button: KeyRecorderButton, context: Context) {
        if button.restingTitle != title { button.restingTitle = title }
        button.isEnabled = enabled
        button.onKeystroke = onKeystroke
        button.onEnd = onEnd
    }
}
