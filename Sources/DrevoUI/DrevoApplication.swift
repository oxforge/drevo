import AppKit

public enum DrevoApplication {
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    public static func main(arguments: [String]) {
        let options = LaunchOptions(arguments: arguments)
        let app = NSApplication.shared
        let delegate = AppDelegate(options: options)
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
