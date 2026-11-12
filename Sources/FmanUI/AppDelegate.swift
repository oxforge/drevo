import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    private(set) var windowControllers: [MainWindowController] = []

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch options.appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let wc = MainWindowController()
        windowControllers.append(wc)
        wc.showWindow(nil)
        NSApp.activate()

        if let path = options.snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                do {
                    try Snapshot.write(window: wc.window!, to: URL(fileURLWithPath: path))
                    exit(0)
                } catch {
                    FileHandle.standardError.write("snapshot failed: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
