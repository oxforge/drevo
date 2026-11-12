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

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch options.appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        env = options.ephemeralSettings ? .ephemeral() : AppEnvironment(preferences: .shared)
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
            wc = openWindow(directories: saved.directories, viewModes: saved.viewModes)
            wc.paneGroup.activate(index: saved.activeIndex)
        } else {
            wc = openWindow(directories: initialDirectories())
        }
        NSApp.activate()

        if let path = options.snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                do {
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
        while dirs.count < max(count, options.openPaths.isEmpty ? count : dirs.count) { dirs.append(dirs.last ?? home) }
        return dirs
    }

    @discardableResult
    func openWindow(directories: [URL], viewModes: [ViewMode] = []) -> MainWindowController {
        let wc = MainWindowController(env: env, directories: directories, viewModes: viewModes, autosave: !options.ephemeralSettings)
        windowControllers.append(wc)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: wc.window, queue: .main) { [weak self, weak wc] _ in
            MainActor.assumeIsolated { self?.windowControllers.removeAll { $0 === wc } }
        })
        wc.showWindow(nil)
        return wc
    }

    @objc func newWindow(_ sender: Any?) {
        if let group = windowControllers.last?.paneGroup {
            openWindow(directories: group.panes.map(\.currentDirectory), viewModes: group.panes.map(\.viewMode))
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

    @objc func showSettings(_ sender: Any?) {}

    @objc func showShortcuts(_ sender: Any?) {}

    @objc func editKeyBindings(_ sender: Any?) {}

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }
}
