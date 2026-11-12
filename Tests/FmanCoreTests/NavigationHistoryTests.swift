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
