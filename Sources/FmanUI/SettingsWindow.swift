import AppKit
import FmanCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Bridges `Preferences` to SwiftUI and refreshes when values change anywhere.
@MainActor
final class SettingsModel: ObservableObject {
    let env: AppEnvironment
    @Published private var tick = 0
    @Published var defaultFolderApp: String = ""
    @Published var loginItemStatus: String = ""
    private var observer: NSObjectProtocol?

    init(env: AppEnvironment) {
        self.env = env
        observer = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: env.preferences, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick += 1 }
        }
        refreshIntegration()
    }

    var prefs: Preferences { env.preferences }

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { [unowned self] in _ = self.tick; return self.prefs[keyPath: keyPath] },
                set: { [unowned self] in self.prefs[keyPath: keyPath] = $0 })
    }

    // MARK: Integration

    func refreshIntegration() {
        let app = NSWorkspace.shared.urlForApplication(toOpen: .folder)
        defaultFolderApp = app.map { FileManager.default.displayName(atPath: $0.path) } ?? "Finder"
        switch SMAppService.mainApp.status {
        case .enabled: loginItemStatus = "on"
        case .requiresApproval: loginItemStatus = "waiting for approval in System Settings ▸ General ▸ Login Items"
        default: loginItemStatus = "off"
        }
    }

    var isDefaultFolderViewer: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: .folder)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    func setDefaultFolderViewer(_ useFman: Bool) {
        let app = useFman ? Bundle.main.bundleURL : URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .folder) { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error { self?.env.operations.prompts.showError("Couldn’t change the folder viewer.", detail: error.localizedDescription, in: nil) }
                    self?.refreshIntegration()
                }
            }
        }
    }

    var revealRedirect: Bool {
        get { _ = tick; return FileViewerSetting.isFman }
        set { FileViewerSetting.set(newValue); tick += 1 }
    }

    var openAtLogin: Bool {
        get { _ = tick; return SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                env.operations.prompts.showError("Couldn’t change Open at Login.", detail: error.localizedDescription, in: nil)
            }
            refreshIntegration()
            tick += 1
        }
    }
}

/// The global `NSFileViewer` default many apps use for "Show in Finder".
enum FileViewerSetting {
    static let key = "NSFileViewer" as CFString

    static var current: String? {
        CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    static var isFman: Bool { current == Bundle.main.bundleIdentifier }

    static func set(_ useFman: Bool) {
        let value: CFPropertyList? = useFman ? (Bundle.main.bundleIdentifier ?? Fman.bundleIdentifier) as CFString : nil
        CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
            AppearanceTab(model: model).tabItem { Label("Appearance", systemImage: "eye") }
            ShellTab(model: model).tabItem { Label("Shell", systemImage: "terminal") }
            IntegrationTab(model: model).tabItem { Label("Finder", systemImage: "macwindow.on.rectangle") }
            KeysTab(model: model).tabItem { Label("Keys", systemImage: "keyboard") }
        }
        .frame(width: 580, height: 470)
        .padding(.vertical, 8)
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Picker("Return key", selection: model.binding(\.returnRenames)) {
                Text("Opens the item (Commander style)").tag(false)
                Text("Renames the item (Finder style)").tag(true)
            }
            Toggle("Ask for the destination before Copy/Move to Other Pane (F5/F6)", isOn: model.binding(\.confirmTransfers))
            Toggle("Keep folders above files", isOn: model.binding(\.foldersFirst))
            Picker("New panes open as", selection: model.binding(\.defaultViewMode)) {
                Text("Columns").tag(ViewMode.columns)
                Text("List").tag(ViewMode.list)
            }
            Stepper("Panes in new windows: \(model.prefs.paneCount)", value: model.binding(\.paneCount), in: 1...4)
            Toggle("Reopen the same folders at launch", isOn: model.binding(\.restoreState))
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Toggle("Show hidden files (⇧⌘.)", isOn: model.binding(\.showHidden))
            Toggle("Show all file extensions", isOn: model.binding(\.showAllExtensions))
            Picker("Row size", selection: model.binding(\.rowSize)) {
                ForEach(RowSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Relative dates (Today, Yesterday)", isOn: model.binding(\.relativeDates))
            Section("Show") {
                Toggle("Sidebar", isOn: model.binding(\.showSidebar))
                Toggle("Status bar under each pane", isOn: model.binding(\.showStatusBar))
                Toggle("Command line", isOn: model.binding(\.showCommandLine))
                Toggle("Key hints at the bottom", isOn: model.binding(\.showKeyHints))
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShellTab: View {
    @ObservedObject var model: SettingsModel

    private var terminals: [URL] { TerminalLauncher.installedTerminals() }
    private static let editors = [
        "/Applications/Visual Studio Code.app", "/Applications/Cursor.app", "/Applications/Zed.app",
        "/Applications/Sublime Text.app", "/Applications/BBEdit.app", "/Applications/Nova.app",
        "/System/Applications/TextEdit.app",
    ]

    var body: some View {
        Form {
            Picker("Terminal app (⌥⌘T, ⌘↩)", selection: Binding(
                get: { model.prefs.terminalAppPath ?? TerminalLauncher.defaultTerminal.path },
                set: { model.prefs.terminalAppPath = $0 })) {
                ForEach(terminals, id: \.path) { Text(FileManager.default.displayName(atPath: $0.path)).tag($0.path) }
            }
            LabeledContent("Shell") {
                Text("\(UserShell.loginShell()) (your login shell)").foregroundStyle(.secondary)
            }
            Toggle("Load interactive config (~/.zshrc, aliases)", isOn: model.binding(\.interactiveShell))
            Text("Commands run as “shell -l -i -c command” in the active pane’s folder. Turn this off if your shell config is slow or prints prompts.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Editor for F4", selection: Binding(
                get: { model.prefs.editorAppPath ?? "" },
                set: { model.prefs.editorAppPath = $0.isEmpty ? nil : $0 })) {
                Text("Default app for text").tag("")
                ForEach(Self.editors.filter { FileManager.default.fileExists(atPath: $0) }, id: \.self) {
                    Text(FileManager.default.displayName(atPath: $0)).tag($0)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct IntegrationTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section {
                LabeledContent("Folders open in") { Text(model.defaultFolderApp) }
                HStack {
                    Button("Use fman for Folders") { model.setDefaultFolderViewer(true) }
                        .disabled(model.isDefaultFolderViewer)
                    Button("Restore Finder") { model.setDefaultFolderViewer(false) }
                        .disabled(!model.isDefaultFolderViewer)
                }
                Text("Folders you open from other apps, the Dock or `open` in Terminal go to fman. Finder keeps running for the Desktop and Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Default folder viewer") }
            Section {
                Toggle("Use fman for “Show in Finder” in other apps", isOn: Binding(
                    get: { model.revealRedirect }, set: { model.revealRedirect = $0 }))
                Text("Sets the system NSFileViewer default. Apps pick it up after they restart; some apps always use Finder.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Reveal") }
            Section {
                Toggle("Open fman at login", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
                Text("Status: \(model.loginItemStatus). Move fman.app to /Applications before turning these on.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Startup") }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshIntegration() }
    }
}

private struct KeysTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(AttributedString(ShortcutsWindow.text(keyMap: model.env.keyMap)))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 380)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Edit keybindings.json") { NSApp.sendAction(#selector(AppDelegate.editKeyBindings(_:)), to: nil, from: nil) }
                Text("Changes apply when you switch back to fman.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

/// The Settings window (⌘,).
@MainActor
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show(env: AppEnvironment) {
        let wc = shared ?? SettingsWindowController(env: env)
        shared = wc
        wc.window?.center()
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    private init(env: AppEnvironment) {
        let hosting = NSHostingController(rootView: SettingsView(model: SettingsModel(env: env)))
        let window = NSWindow(contentViewController: hosting)
        window.title = "fman Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
