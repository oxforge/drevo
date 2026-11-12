import AppKit
import FmanCore
import UniformTypeIdentifiers

/// The apps Settings offers as the editor for F4.
enum EditorChoices {
    /// Where apps are installed. macOS also lists helper copies of apps that sit in
    /// caches and temporary folders (test browsers, code-sign clones); those are noise.
    static var appFolders: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         URL(fileURLWithPath: "/System/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Every installed app that says it opens plain text, plus the chosen one.
    @MainActor
    static func installed(chosen: String?) -> [URL] {
        list(candidates: NSWorkspace.shared.urlsForApplications(toOpen: UTType.plainText), chosen: chosen, appFolders: appFolders)
    }

    /// `candidates` inside `appFolders`, plus the `chosen` app wherever it is (it may
    /// have been picked by hand), each once, by name. Apps no longer on disk are left out.
    static func list(candidates: [URL], chosen: String?, appFolders: [URL]) -> [URL] {
        let picked = chosen.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let offered = candidates.filter { app in appFolders.contains { app.isInside($0) } }
        var seen = Set<String>()
        return ([picked].compactMap { $0 } + offered)
            .map(\.standardizedFileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Asks for any app on disk; nil if the user cancels.
    @MainActor
    static func chooseOther() -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = appFolders[0]
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the app that F4 opens files in."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
