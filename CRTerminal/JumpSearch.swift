import Foundation

/// One searchable attribute of a session ("command", "directory",
/// "branch", …). The matcher is kind-agnostic: making a new attribute
/// searchable means emitting another facet (see
/// `JumpTargetBuilder.facetProviders`), never touching the ranking.
nonisolated struct SessionFacet: Equatable, Sendable {
    var kind: String
    var text: String
    /// Relative score multiplier when this facet matches (titles beat
    /// directories, etc.).
    var weight: Double = 1
}

nonisolated protocol JumpSearchable {
    var facets: [SessionFacet] { get }
}

/// Ranks jump-menu candidates against a free-text query. Tokens are ANDed:
/// every whitespace-separated token must match some facet, but different
/// tokens may hit different facets ("main mcq" finds the session on branch
/// `main` in `~/dev/mcq-master`). Matching is case-insensitive substring,
/// boosted for word-start and text-start hits.
nonisolated enum JumpSearch {
    static func rank<T: JumpSearchable>(_ items: [T], query: String) -> [T] {
        let tokens = query.lowercased()
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return items }
        var scored: [(order: Int, score: Double, item: T)] = []
        for (order, item) in items.enumerated() {
            if let score = score(item.facets, tokens: tokens) {
                scored.append((order, score, item))
            }
        }
        return scored
            .sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
            .map(\.item)
    }

    /// Nil when some token matches no facet (the item is filtered out).
    private static func score(_ facets: [SessionFacet], tokens: [String]) -> Double? {
        var total = 0.0
        for token in tokens {
            var best = 0.0
            for facet in facets {
                best = max(best, quality(of: token, in: facet.text.lowercased()) * facet.weight)
            }
            guard best > 0 else { return nil }
            total += best
        }
        return total
    }

    /// 3 = starts the text, 2 = starts a word, 1 = substring, 0 = no match.
    private static func quality(of token: String, in text: String) -> Double {
        var best = 0.0
        var searchFrom = text.startIndex
        while let range = text.range(of: token, range: searchFrom..<text.endIndex) {
            if range.lowerBound == text.startIndex {
                return 3
            }
            let before = text[text.index(before: range.lowerBound)]
            best = max(best, wordBoundaries.contains(before) ? 2 : 1)
            searchFrom = text.index(after: range.lowerBound)
        }
        return best
    }

    private static let wordBoundaries = Set(" /-_.~·")
}
