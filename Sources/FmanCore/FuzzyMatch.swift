import Foundation

/// Subsequence matching for the command palette: "cpo" matches "Copy to Other Pane".
public enum FuzzyMatch {
    public struct Match: Equatable, Sendable {
        public let score: Int
        /// Offsets (in Characters) of matched characters, for highlighting.
        public let positions: [Int]
    }

    public static func match(_ query: String, in candidate: String) -> Match? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        if q.isEmpty { return Match(score: 0, positions: []) }
        let c = Array(candidate)
        let lower = c.map { Character($0.lowercased()) }
        var positions: [Int] = []
        var score = 0
        var qi = 0
        var previous = -2
        for (i, ch) in lower.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            var points = 1
            let wordStart = i == 0 || !c[i - 1].isLetter && !c[i - 1].isNumber || (c[i].isUppercase && c[i - 1].isLowercase)
            if wordStart { points += 8 }
            if i == previous + 1 { points += 5 }
            if i == 0 { points += 3 }
            score += points
            positions.append(i)
            previous = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Prefer shorter candidates when scores tie.
        score -= c.count / 8
        return Match(score: score, positions: positions)
    }

    /// Candidates that match, best first; ties keep input order.
    public static func rank<T>(_ query: String, _ items: [T], text: (T) -> String) -> [(item: T, match: Match)] {
        items.enumerated()
            .compactMap { idx, item in match(query, in: text(item)).map { (idx, item, $0) } }
            .sorted { $0.2.score != $1.2.score ? $0.2.score > $1.2.score : $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
    }
}
