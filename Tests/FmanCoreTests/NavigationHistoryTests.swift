import Foundation
import Testing
@testable import FmanCore

@Test func backAndForward() {
    let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b"), c = URL(fileURLWithPath: "/c")
    var h = NavigationHistory(start: a)
    h.visit(b)
    h.visit(c)
    #expect(h.goBack() == b)
    #expect(h.goBack() == a)
    #expect(h.goBack() == nil)
    #expect(h.goForward() == b)
    h.visit(a)
    #expect(!h.canGoForward, "visiting clears forward history")
    #expect(h.backStack == [a, b])
}

@Test func visitingCurrentFolderIsANoOp() {
    var h = NavigationHistory(start: URL(fileURLWithPath: "/a"))
    h.visit(URL(fileURLWithPath: "/a/"))
    #expect(!h.canGoBack)
}

@Test func historyIsBounded() {
    var h = NavigationHistory(start: URL(fileURLWithPath: "/0"))
    h.limit = 3
    for i in 1...10 { h.visit(URL(fileURLWithPath: "/\(i)")) }
    #expect(h.backStack.count == 3)
    #expect(h.backStack.first == URL(fileURLWithPath: "/7"))
}

/// The current folder was deleted and its parent is shown instead: Back must not lead
/// to the folder that is gone, and it must not need a second press to leave the parent.
@Test func replacingTheCurrentFolderLeavesNoTraceOfIt() {
    let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/a/b"), c = URL(fileURLWithPath: "/a/b/c")
    let other = URL(fileURLWithPath: "/other")

    // Came from elsewhere: the stacks stay as they are.
    var h = NavigationHistory(start: other)
    h.visit(c)
    h.replaceCurrent(with: b)
    #expect(h.current == b)
    #expect(h.backStack == [other], "the vanished folder isn't pushed")
    #expect(!h.canGoForward)
    #expect(h.goBack() == other)
    #expect(h.goForward() == b, "Forward returns to the replacement, not to the vanished folder")

    // Came down from the parent: it isn't its own Back entry.
    h = NavigationHistory(start: a)
    h.visit(b)
    h.visit(c)
    h.replaceCurrent(with: b)
    #expect(h.current == b)
    #expect(h.backStack == [a])
    #expect(h.goBack() == a)

    // Went back from the parent to the folder: the parent isn't its own Forward entry.
    h = NavigationHistory(start: c)
    h.visit(b)
    h.visit(other)
    h.goBack()
    h.goBack()
    #expect(h.current == c)
    #expect(h.forwardStack == [other, b])
    h.replaceCurrent(with: b)
    #expect(h.forwardStack == [other])
    #expect(h.goForward() == other)

    // Nothing to replace: no change.
    h = NavigationHistory(start: a)
    h.visit(b)
    h.replaceCurrent(with: URL(fileURLWithPath: "/a/b/"))
    #expect(h.backStack == [a])
    #expect(h.current.path == "/a/b")
}
