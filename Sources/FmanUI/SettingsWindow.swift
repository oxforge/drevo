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
    private var observers: [NSObjectProtocol] = []

    init(env: AppEnvironment) {
        self.env = env
        // Preferences, and the shell setup's state shown in the Shell tab.
        let sources: [(Notification.Name, AnyObject)] = [(Preferences.didChange, env.preferences), (ShellSetup.didChange, env.shellSetup)]
        observers = sources.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick += 1 }
            }
        }
        refreshIntegration()
    }

    var prefs: Preferences { env.preferences }

    var shellSetupStatus: String {
        _ = tick
        let setup = env.shellSetup
        if !setup.isSupported { return "\((setup.shell as NSString).lastPathComponent): config is loaded for every command." }
        if setup.isLoading { return "Loading…" }
        if let error = setup.lastError { return "Last load failed: \(error)" }
        if let s = setup.snapshot, let d = setup.lastCaptureDuration {
            return String(format: "Loaded in %.1f s, %@.", d, RelativeDateTimeFormatter().localizedString(for: s.capturedAt, relativeTo: Date()))
        }
        return "Loads the first time you use the command line."
    }

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

    /// Set after macOS refused to change the folder app, to explain it in the tab.
    @Published var folderViewerRefused = false

    func setDefaultFolderViewer(_ useFman: Bool) {
        let app = useFman ? Bundle.main.bundleURL : URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .folder) { [weak self] error in
            onMainRunLoop {
                guard let self else { return }
                if let error {
                    let problem = FolderViewerProblem(error)
                    self.folderViewerRefused = problem.refusedByMacOS
                    self.env.operations.prompts.showError(problem.title, detail: problem.detail, in: nil)
                }
                self.refreshIntegration()
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
            Toggle("Use my shell config (~/.zshrc: aliases, functions, PATH)", isOn: model.binding(\.interactiveShell))
            Text("fman loads your config once (a full login shell) and reuses it, so each command starts in milliseconds. It reloads when your startup files change, or after an hour. Not reused: `setopt` options and unexported variables.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reload Shell Config") { model.env.shellSetup.reload() }
                    .disabled(!model.env.shellSetup.isSupported)
                Text(model.shellSetupStatus).font(.caption).foregroundStyle(.secondary)
            }
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

struct IntegrationTab: View {
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
                if model.folderViewerRefused {
                    Text("macOS refused: on this version folders always open in Finder, and no other app can take that over. Use the options below instead.")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Asks macOS to open folders from other apps, the Dock or `open` in Terminal in fman. Recent macOS versions refuse this; fman will tell you if so.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Default folder viewer") }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• In Finder, right-click a folder ▸ Services ▸ **Open in fman**. Give it a shortcut in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services.")
                    Text("• ⌘-drag fman.app from Applications into Finder’s toolbar, then drop folders on it.")
                    Text("• Drop folders on fman’s Dock icon.")
                    Text("• In Terminal: `open -a fman .`")
                }
                .font(.caption)
                Button("Open Keyboard Shortcuts…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            } header: { Text("Open folders in fman") }
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
