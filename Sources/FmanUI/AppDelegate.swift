import AppKit
import FmanCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    private(set) var env: AppEnvironment!
    private(set) var windowControllers: [MainWindowController] = []
    private var observers: [NSObjectProtocol] = []

    init(options: LaunchOptions) {
        self.options = options
    }

    /// Tests drive the delegate without launching the app.
    func useEnvironmentForTests(_ env: AppEnvironment) {
        self.env = env
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleReveal(_:withReply:)),
                                                     forEventClass: AEEventClass(kAEMiscStandards),
                                                     andEventID: AEEventID(kAEMakeObjectsVisible))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        switch options.appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        env = options.ephemeralSettings ? .ephemeral() : AppEnvironment(preferences: .shared)
        keyBindingsStamp = Self.modificationDate(KeyMap.userOverridesURL)
        NSApp.mainMenu = MainMenu.build(keyMap: env.keyMap)
        observers.append(NotificationCenter.default.addObserver(forName: AppEnvironment.keyMapDidChange, object: env, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSApp.mainMenu = MainMenu.build(keyMap: self.env.keyMap)
            }
        })

        let wc: MainWindowController
        if options.openPaths.isEmpty, env.preferences.restoreState,
           let saved = WindowState.decode(env.preferences.savedWindowState)?.validated() {
            wc = openWindow(directories: saved.directories, viewModes: saved.viewModes, sorts: saved.sorts)
            wc.paneGroup.activate(index: saved.activeIndex)
        } else {
            wc = openWindow(directories: initialDirectories())
        }
        NSApp.activate()

        if let path = options.snapshotPath {
            if let command = options.snapshotCommand {
                wc.commandBar.field.stringValue = command
                wc.commandBar.submit(inTerminal: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (options.snapshotCommand == nil ? 0.8 : 2.5)) {
                do {
                    if self.options.snapshotSettings {
                        self.showSettings(nil)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                        if let w = NSApp.windows.first(where: { $0.title == "fman Settings" }) {
                            try Snapshot.write(window: w, to: URL(fileURLWithPath: path))
                            exit(0)
                        }
                    }
                    try Snapshot.write(window: wc.window!, overlays: [wc.sidebar.view], to: URL(fileURLWithPath: path))
                    exit(0)
                } catch {
                    FileHandle.standardError.write("snapshot failed: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
        }
    }

    private func initialDirectories() -> [URL] {
        let count = env.preferences.paneCount
        var dirs = options.openPaths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        while dirs.count < count { dirs.append(dirs.last ?? home) }
        return dirs
    }

    @discardableResult
    func openWindow(directories: [URL], viewModes: [ViewMode] = [], sorts: [FileSort] = []) -> MainWindowController {
        let wc = MainWindowController(env: env, directories: directories, viewModes: viewModes, sorts: sorts, autosave: !options.ephemeralSettings)
        windowControllers.append(wc)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: wc.window, queue: .main) { [weak self, weak wc] _ in
            // The window controller stops its own command when it closes.
            MainActor.assumeIsolated { self?.windowControllers.removeAll { $0 === wc } }
        })
        wc.showWindow(nil)
        return wc
    }

    @objc func newWindow(_ sender: Any?) {
        if let group = windowControllers.last?.paneGroup {
            openWindow(directories: group.panes.map(\.currentDirectory), viewModes: group.panes.map(\.viewMode), sorts: group.panes.map(\.sort))
        } else {
            openWindow(directories: initialDirectories())
        }
    }

    /// Menu commands with no window open (only New Window works then).
    @objc func performCommand(_ sender: Any?) {
        if (sender as? NSMenuItem)?.representedObject as? String == CommandID.newWindow.rawValue {
            newWindow(sender)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.show(env: env)
    }

    // MARK: Opening folders from elsewhere (Dock, `open -a fman`, default folder viewer)

    func application(_ application: NSApplication, open urls: [URL]) {
        show(urls)
    }

    /// Folders open in the active pane; files are revealed (their folder opens with them selected).
    func show(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let wc = frontWindowController ?? openWindow(directories: [first.deletingLastPathComponent(), first.deletingLastPathComponent()])
        let pane = wc.paneGroup.activePane
        let isFolder = first.isDirectoryOnDisk && (try? FileItem(url: first))?.isContainer == true
        pane.navigate(to: first)
        if !isFolder {
            let siblings = urls.filter { $0.deletingLastPathComponent() == first.deletingLastPathComponent() }
            if siblings.count > 1 { pane.browser.select(siblings) }
        }
        wc.window?.makeKeyAndOrderFront(nil)
        pane.focus()
        NSApp.activate()
    }

    private var frontWindowController: MainWindowController? {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController { return key }
        if let main = NSApp.mainWindow?.windowController as? MainWindowController { return main }
        return windowControllers.last
    }

    /// "Show in Finder" from other apps when NSFileViewer points at fman ('misc'/'mvis').
    @objc func handleReveal(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        show(Self.fileURLs(in: event))
    }

    static func fileURLs(in event: NSAppleEventDescriptor) -> [URL] {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return [] }
        if direct.numberOfItems == 0 {
            return [direct.coerce(toDescriptorType: typeFileURL)?.fileURLValue].compactMap { $0 }
        }
        return (1...direct.numberOfItems).compactMap { direct.atIndex($0)?.coerce(toDescriptorType: typeFileURL)?.fileURLValue }
    }

    /// Services ▸ Open in fman (Finder's context menu, any app with files).
    @objc func openInFman(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        show(urls)
    }

    @objc func showShortcuts(_ sender: Any?) {
        ShortcutsWindow.show(keyMap: env.keyMap)
    }

    /// Writes keybindings.json (if missing) and the defaults reference, then opens it.
    @objc func editKeyBindings(_ sender: Any?) {
        let url = KeyMap.userOverridesURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try KeyMap().templateJSON().write(to: dir.appendingPathComponent("keybindings.defaults.json"), atomically: true, encoding: .utf8)
            if !FileManager.default.fileExists(atPath: url.path) {
                try KeyMap.starterJSON.write(to: url, atomically: true, encoding: .utf8)
            }
            let editor = env.preferences.editorAppPath.map { URL(fileURLWithPath: $0) }
                ?? NSWorkspace.shared.urlForApplication(toOpen: .plainText)
                ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            env.opener.open([url], withApplicationAt: editor)
            keyBindingsStamp = Self.modificationDate(url)
        } catch {
            env.operations.prompts.showError("Couldn’t create keybindings.json.", detail: error.localizedDescription, in: NSApp.keyWindow)
        }
    }

    private var keyBindingsStamp: Date?

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Picks up keybindings.json edits when the user comes back to fman.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !options.ephemeralSettings else { return }
        let stamp = Self.modificationDate(KeyMap.userOverridesURL)
        guard stamp != keyBindingsStamp else { return }
        keyBindingsStamp = stamp
        env.reloadKeyMap()
        var problems = env.keyMapProblems
        let conflicts = env.keyMap.conflicts.map { "\($0.key) is bound to \($0.value.map(\.rawValue).joined(separator: " and "))" }
        problems += conflicts
        if !problems.isEmpty {
            env.operations.prompts.showError("Some key bindings weren’t applied.", detail: problems.joined(separator: "\n"), in: NSApp.keyWindow)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting mid-copy would leave half-copied items under their final names: ask, then
    /// stop the jobs (transfers, archive expansions) and wait for their cleanup before quitting. Running shell
    /// commands are ended once quitting is certain, so they don't outlive the app; "Keep
    /// Running" leaves them alone.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let ops = env.operations
        guard !ops.jobs.isEmpty else {
            endShellCommands()
            return .terminateNow
        }
        guard confirmQuit(ops.jobs.count) else { return .terminateCancel }
        windowControllers.forEach { $0.shell.stop() } // Ctrl-C now; they get the cleanup time to exit
        ops.cancelAll()
        quitObserver = NotificationCenter.default.addObserver(forName: OperationsCenter.jobsDidChange, object: ops, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.env.operations.jobs.isEmpty else { return }
                if let token = self.quitObserver { NotificationCenter.default.removeObserver(token) }
                self.quitObserver = nil
                self.endShellCommands()
                self.replyToTerminate(true)
            }
        }
        return .terminateLater
    }

    /// Waits for cancelled transfers to finish cleaning up before quitting.
    private var quitObserver: NSObjectProtocol?

    /// "Stop and Quit" (true) or "Keep Running" for `jobCount` unfinished jobs (copies,
    /// moves, archives being expanded). Tests replace the alert with a scripted answer.
    var confirmQuit: (_ jobCount: Int) -> Bool = { jobCount in
        let alert = NSAlert()
        alert.messageText = AppDelegate.quitQuestion(jobCount: jobCount)
        alert.informativeText = "Quitting stops \(jobCount == 1 ? "it" : "them"); items that weren’t finished are removed."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Running")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The quit alert's headline; it fits whatever the jobs are doing.
    nonisolated static func quitQuestion(jobCount: Int) -> String {
        jobCount == 1 ? "A file operation is still running." : "\(jobCount) file operations are still running."
    }

    /// The answer after `.terminateLater`. Tests record it instead of quitting.
    var replyToTerminate: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    /// Ends every window's command for certain: the app is about to exit, so nothing
    /// could follow up on a command that ignores Ctrl-C.
    private func endShellCommands() {
        windowControllers.forEach { $0.shell.terminate() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }
}
