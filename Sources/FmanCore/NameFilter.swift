import Foundation

/// The pane filter's rule for names, ignoring case and accents. Plain text matches names
/// that contain it. Text with `*` (any run of characters) or `?` (one character) is a
/// pattern the whole name must match: `*.png`, `img_*`. Other characters, brackets
/// included, stand for themselves.
public struct NameFilter: Sendable {
    private let needle: [Character]
    private let isPattern: Bool

    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        needle = Array(Self.fold(trimmed))
        isPattern = trimmed.contains { $0 == "*" || $0 == "?" }
    }

    public var isEmpty: Bool { needle.isEmpty }

    public func matches(_ name: String) -> Bool {
        if isEmpty { return true }
        let folded = Self.fold(name)
        if !isPattern { return folded.contains(String(needle)) }
        return Self.glob(needle, Array(folded))
    }

    private static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Wildcard match; on a mismatch, the most recent `*` takes one more character.
    private static func glob(_ pattern: [Character], _ name: [Character]) -> Bool {
        var p = 0, n = 0
        var star: Int?, starN = 0
        while n < name.count {
            if p < pattern.count, pattern[p] == "?" || (pattern[p] != "*" && pattern[p] == name[n]) {
                p += 1
                n += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p
                starN = n
                p += 1
            } else if let s = star {
                p = s + 1
                starN += 1
                n = starN
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
