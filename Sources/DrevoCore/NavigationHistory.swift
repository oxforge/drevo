import Foundation

/// Browser-style back/forward history of folders for one pane.
public struct NavigationHistory: Equatable, Sendable {
    public private(set) var current: URL
    public private(set) var backStack: [URL] = []
    public private(set) var forwardStack: [URL] = []
    public var limit = 100

    public init(start: URL) {
        current = start
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Moves to `url`, recording the current folder; clears forward history.
    public mutating func visit(_ url: URL) {
        guard url.standardizedFileURL.path != current.standardizedFileURL.path else { return }
        backStack.append(current)
        if backStack.count > limit { backStack.removeFirst(backStack.count - limit) }
        forwardStack.removeAll()
        current = url
    }

    /// The current folder is gone (deleted outside the app) and `url` is shown in its
    /// place. Unlike `visit`, the vanished folder isn't recorded: Back must not lead to
    /// it. If `url` is also the next Back or Forward entry, that entry is dropped, so
    /// one press still goes somewhere else.
    public mutating func replaceCurrent(with url: URL) {
        let path = url.standardizedFileURL.path
        guard path != current.standardizedFileURL.path else { return }
        current = url
        if backStack.last?.standardizedFileURL.path == path { backStack.removeLast() }
        if forwardStack.last?.standardizedFileURL.path == path { forwardStack.removeLast() }
    }

    @discardableResult
    public mutating func goBack() -> URL? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = previous
        return previous
    }

    @discardableResult
    public mutating func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = next
        return next
    }
}
