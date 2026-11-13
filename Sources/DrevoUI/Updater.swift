import AppKit
import DrevoCore
import Security

/// Drevo ▸ Check for Updates…: asks GitHub for the latest release, offers a newer one,
/// downloads its disk image, checks the app in it against the running app's signature,
/// and replaces the app when Drevo quits, then starts it again.
@MainActor
final class Updater {
    /// Everything that reaches outside the process; tests script all of it.
    struct Services {
        var currentVersion: AppVersion?
        /// The bundle to replace.
        var installedApp: URL
        var latestRelease: (_ completion: @escaping @MainActor (Result<AppRelease, Error>) -> Void) -> Void
        /// Downloads the image and leaves the new app, checked, next to the installed one.
        var fetch: (_ diskImage: URL, _ installed: URL, _ cancel: CancellationToken,
                    _ progress: @escaping @MainActor (Double) -> Void,
                    _ completion: @escaping @MainActor (Result<URL, Error>) -> Void) -> Void
        var openPage: (URL) -> Void
        var quit: () -> Void
        var relaunch: (URL) -> Void
        var showsProgressPanel = true
    }

    private var services: Services
    private let prompts: UserPrompts
    private var busy = false
    private var progressPanel: UpdateProgressPanel?
    /// The downloaded app, waiting next to the installed one for the quit.
    private(set) var staged: (app: URL, version: AppVersion)?

    init(services: Services = .live, prompts: UserPrompts) {
        self.services = services
        self.prompts = prompts
    }

    func check() {
        guard !busy else { return }
        busy = true
        services.latestRelease { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .failure(let error):
                self.prompts.showError("Drevo couldn’t check for updates.", detail: error.localizedDescription, in: nil)
            case .success(let release):
                self.consider(release)
            }
        }
    }

    private func consider(_ release: AppRelease) {
        guard let current = services.currentVersion else {
            return offerPage(release, "This copy of Drevo doesn’t know its own version, so it can’t tell whether \(release.version) is newer.")
        }
        guard release.version > current else {
            return prompts.showInfo("You’re up to date.", detail: "Drevo \(current) is the latest version.", in: nil)
        }
        prompts.offerUpdate(version: release.version.description, current: current.description, notes: release.notes, in: nil) { [weak self] install in
            if install { self?.install(release) }
        }
    }

    private func install(_ release: AppRelease) {
        if let staged, staged.version == release.version { return services.quit() }
        if let obstacle = AppInstall.obstacle(for: services.installedApp) { return offerPage(release, obstacle) }
        guard let image = release.diskImage else { return offerPage(release, "The release has no disk image to install from.") }
        busy = true
        let cancel = CancellationToken()
        if services.showsProgressPanel {
            progressPanel = UpdateProgressPanel(title: "Downloading Drevo \(release.version)…") { cancel.cancel() }
            progressPanel?.show()
        }
        services.fetch(image, services.installedApp, cancel, { [weak self] fraction in
            self?.progressPanel?.fraction = fraction
        }, { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.progressPanel?.close()
            self.progressPanel = nil
            switch result {
            case .success(let app):
                guard !cancel.isCancelled else { return Self.discard(app) }
                self.discardStaged()
                self.staged = (app, release.version)
                self.services.quit()
            case .failure(let error):
                if !cancel.isCancelled { self.offerPage(release, error.localizedDescription) }
            }
        })
    }

    /// The update can't be installed from here: say why, and offer the release's page.
    private func offerPage(_ release: AppRelease, _ reason: String) {
        prompts.confirm("Drevo \(release.version) can’t be installed automatically.",
                        detail: reason + "\n\nYou can download it from the release page.",
                        button: "Open Release Page", in: nil) { [services] open in
            if open { services.openPage(release.page) }
        }
    }

    /// Called when the app is certain to quit: puts a downloaded update in place and
    /// starts it once this process is gone.
    func finishOnQuit() {
        guard let staged else { return }
        self.staged = nil
        do {
            try AppInstall.swap(staged: staged.app, installed: services.installedApp)
            services.relaunch(services.installedApp)
        } catch {
            NSLog("Drevo update to %@ was not installed: %@", staged.version.description, error.localizedDescription)
            Self.discard(staged.app)
        }
    }

    private func discardStaged() {
        if let staged { Self.discard(staged.app) }
        staged = nil
    }

    private static func discard(_ app: URL) {
        try? FileManager.default.removeItem(at: app)
    }
}

// MARK: - The real services

extension Updater.Services {
    static let releaseURL = URL(string: "https://api.github.com/repos/oxforge/drevo/releases/latest")!

    static var live: Updater.Services {
        Updater.Services(
            currentVersion: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init),
            installedApp: Bundle.main.bundleURL,
            latestRelease: { completion in
                var request = URLRequest(url: releaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                URLSession.shared.dataTask(with: request) { data, response, error in
                    let result = Result<AppRelease, Error> {
                        if let error { throw error }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        guard status == 200, let data else { throw UpdateFetch.Failure(UpdateFetch.message(forStatus: status)) }
                        return try AppRelease.parse(data)
                    }
                    onMainRunLoop { completion(result) }
                }.resume()
            },
            fetch: UpdateFetch.run,
            openPage: { NSWorkspace.shared.open($0) },
            quit: { NSApp.terminate(nil) },
            relaunch: UpdateFetch.relaunch)
    }
}

/// Download, mount, copy and check: the slow part of an update, off the main thread.
enum UpdateFetch {
    struct Failure: Error, LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }

    static func message(forStatus status: Int) -> String {
        switch status {
        case 404: return "No release has been published yet."
        case 403, 429: return "GitHub is limiting requests from this network. Try again later."
        default: return "GitHub answered with status \(status)."
        }
    }

    static func run(diskImage: URL, installed: URL, cancel: CancellationToken,
                    progress: @escaping @MainActor (Double) -> Void,
                    completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("drevo-update-\(UUID().uuidString)", isDirectory: true)
        let image = scratch.appendingPathComponent("Drevo.dmg")
        var observation: NSKeyValueObservation?
        let task = URLSession.shared.downloadTask(with: diskImage) { file, response, error in
            observation?.invalidate()
            let result = Result<URL, Error> {
                defer { try? FileManager.default.removeItem(at: scratch) }
                if let error { throw error }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let file else { throw Failure("The download failed (status \(status)).") }
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: file, to: image)
                return try stageApp(from: image, mountAt: scratch.appendingPathComponent("image"), installed: installed, cancel: cancel)
            }
            onMainRunLoop { completion(result) }
        }
        observation = task.progress.observe(\.fractionCompleted) { p, _ in
            let fraction = p.fractionCompleted
            onMainRunLoop { progress(fraction) }
        }
        task.resume()
        // The token is only a flag: watch it to stop the download itself.
        let watch = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "drevo.update.cancel"))
        watch.schedule(deadline: .now() + 0.2, repeating: 0.2)
        watch.setEventHandler {
            if cancel.isCancelled { task.cancel() }
            if cancel.isCancelled || task.state == .completed { watch.cancel() }
        }
        watch.resume()
    }

    /// Mounts the image, copies its app next to `installed` and checks the copy: it must
    /// carry the running app's signature and a newer version.
    static func stageApp(from image: URL, mountAt mount: URL, installed: URL, cancel: CancellationToken) throws -> URL {
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try hdiutil(["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path],
                    failure: "The downloaded disk image couldn’t be opened.")
        defer { try? hdiutil(["detach", "-force", mount.path], failure: "") }
        let apps = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard let app = apps.first, apps.count == 1 else { throw Failure("The disk image doesn’t hold exactly one app.") }
        if cancel.isCancelled { throw CancellationError() }
        let staged = try AppInstall.stage(app, for: installed)
        do {
            if let problem = CodeSignature.problem(with: staged, updating: installed) { throw Failure(problem) }
            let current = (Bundle(url: installed)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
            let new = (NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
            guard let current, let new, new > current else { throw Failure("The downloaded app isn’t newer than this one.") }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return staged
    }

    private static func hdiutil(_ arguments: [String], failure: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw Failure(failure) }
    }

    /// Opens `app` once this process has exited.
    static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open "$2""#,
                             "sh", String(getpid()), app.path]
        try? process.run()
    }
}

/// Whether a downloaded app comes from whoever signed the running one.
enum CodeSignature {
    /// Nil when `candidate` is intact and meets the designated requirement of `running`
    /// (same identifier, same certificate); otherwise the reason it can't replace it.
    static func problem(with candidate: URL, updating running: URL) -> String? {
        var runningCode: SecStaticCode?
        var candidateCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(running as CFURL, [], &runningCode) == errSecSuccess, let runningCode,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess, let candidateCode else {
            return "The apps’ signatures couldn’t be read."
        }
        var info: CFDictionary?
        SecCodeCopySigningInformation(runningCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let flags = ((info as? [String: Any])?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
        guard let flags else { return "This copy of Drevo isn’t signed, so an update can’t be checked against it." }
        if SecCodeSignatureFlags(rawValue: flags).contains(.adhoc) {
            return "This copy of Drevo was built without a signing certificate, so an update can’t be checked against it."
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(runningCode, [], &requirement) == errSecSuccess, let requirement else {
            return "This copy of Drevo has no signature an update could be checked against."
        }
        let check = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(candidateCode, check, requirement) == errSecSuccess else {
            return "The downloaded app isn’t signed with the same certificate as this copy of Drevo."
        }
        return nil
    }
}

// MARK: - Dialogs

/// A small window with a progress bar and Cancel, shown while the update downloads.
@MainActor
final class UpdateProgressPanel: NSObject {
    private let panel: NSPanel
    private let bar = NSProgressIndicator()
    private let onCancel: () -> Void

    var fraction: Double = 0 {
        didSet {
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        }
    }

    init(title: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 96), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        panel.title = "Software Update"
        panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: title)
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = stack
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 360),
            bar.widthAnchor.constraint(equalToConstant: 328),
        ])
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel.close() }

    @objc private func cancelClicked() { onCancel() }
}

/// Release notes for the update dialog: headings and bold from the Markdown, the rest as written.
enum ReleaseNotes {
    static func text(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for var line in markdown.components(separatedBy: .newlines) {
            var heading = false
            if let marks = line.range(of: "^#{1,6} ", options: .regularExpression) {
                line.removeSubrange(marks)
                heading = true
            }
            let parsed = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(line)
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                var font = NSFont.systemFont(ofSize: 12)
                if heading { font = .boldSystemFont(ofSize: 13) }
                else if intent.contains(.stronglyEmphasized) { font = .boldSystemFont(ofSize: 12) }
                else if intent.contains(.code) { font = .monospacedSystemFont(ofSize: 11, weight: .regular) }
                out.append(NSAttributedString(string: String(parsed[run.range].characters),
                                              attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            }
            out.append(NSAttributedString(string: "\n"))
        }
        return out
    }
}
