import AppKit
import FmanCore

/// The user's shell setup, loaded once (a full `shell -l -i`, ~1–2 s with a heavy
/// ~/.zshrc) and reused by every window, so commands start in milliseconds.
/// Reloads when a startup file changes, after an hour, or on request.
@MainActor
final class ShellSetup {
    /// Posted (object: the setup) when a load starts and when it ends, for anything that
    /// shows the state (Settings ▸ Shell).
    static let didChange = Notification.Name("fman.shellSetupDidChange")

    let shell: String
    /// Tests point this at a scratch config (ZDOTDIR/HOME).
    var captureEnvironment: [String: String]?
    let definitionsFile: URL
    private(set) var snapshot: ShellSnapshot?
    private(set) var lastCaptureDuration: TimeInterval?
    private(set) var lastError: String?
    private(set) var isLoading = false
    private var waiters: [(ShellSnapshot?) -> Void] = []

    init(shell: String = UserShell.loginShell(), definitionsFile: URL? = nil) {
        self.shell = shell
        self.definitionsFile = definitionsFile ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tech.oxforge.fman/shell-definitions.sh")
    }

    /// zsh and bash; other shells start in full for every command.
    var isSupported: Bool { ShellSnapshot.dialect(of: shell) != nil }

    var freshSnapshot: ShellSnapshot? {
        guard let s = snapshot, s.isFresh() else { return nil }
        return s
    }

    /// Start loading in the background if there's no fresh setup (e.g. when the command
    /// line gets focus, so typing hides the wait).
    func prepare() {
        guard isSupported, freshSnapshot == nil, !isLoading else { return }
        load()
    }

    /// The fresh setup, loading it first if needed; nil if it couldn't be loaded.
    func withSnapshot(_ done: @escaping (ShellSnapshot?) -> Void) {
        if let s = freshSnapshot { return done(s) }
        waiters.append(done)
        if !isLoading { load() }
    }

    /// Forget the current setup and load it again (Settings ▸ Shell ▸ Reload).
    func reload() {
        snapshot = nil
        if !isLoading { load() }
    }

    private func load() {
        isLoading = true
        NotificationCenter.default.post(name: Self.didChange, object: self)
        let shell = self.shell
        let env = captureEnvironment
        let file = definitionsFile
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> ShellSnapshot in
                let s = try ShellSnapshot.capture(shell: shell, environment: env)
                try s.writeDefinitions(to: file)
                return s
            }
            onMainRunLoop {
                guard let self else { return }
                self.isLoading = false
                self.lastCaptureDuration = Date().timeIntervalSince(started)
                switch result {
                case .success(let s): self.snapshot = s; self.lastError = nil
                case .failure(let e): self.snapshot = nil; self.lastError = e.localizedDescription
                }
                NotificationCenter.default.post(name: Self.didChange, object: self)
                let waiting = self.waiters
                self.waiters = []
                waiting.forEach { $0(self.snapshot) }
            }
        }
    }
}
