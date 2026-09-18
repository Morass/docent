import Foundation

/// A ranked hit: which docset, which row, and how well it matched.
public struct Match: Hashable, Sendable {
    public let docset: Docset
    public let entry: IndexEntry
    public let score: Int

    public init(docset: Docset, entry: IndexEntry, score: Int) {
        self.docset = docset
        self.entry = entry
        self.score = score
    }
}

/// How a query is turned into an order. Pure, so the interesting cases are unit tests
/// rather than something you have to see on screen to believe.
public enum Ranking {
    /// Higher is better; nil means the name does not match at all.
    ///
    /// The ladder, in the order a person expects: the thing they typed exactly, then what
    /// starts with it, then what starts with it after a separator (`NSString.length` for
    /// `length`), then what merely contains it, then a loose subsequence. Shorter names
    /// win inside each rung, because `map` should beat `mapValues` for the query `map`.
    public static func score(name: String, query: String) -> Int? {
        let query = query.trimmed
        guard !query.isEmpty else { return 1 }
        guard !name.isEmpty else { return nil }

        let lowerName = name.lowercased()
        let lowerQuery = query.lowercased()
        let lengthPenalty = min(name.count, 200)

        if name == query { return 10_000 - lengthPenalty }
        if lowerName == lowerQuery { return 9_000 - lengthPenalty }
        if lowerName.hasPrefix(lowerQuery) { return 8_000 - lengthPenalty }
        if let boundary = boundaryPrefixIndex(name, query) ?? boundaryPrefixIndex(lowerName, lowerQuery) {
            return 7_000 - boundary - lengthPenalty
        }
        if lowerName.contains(lowerQuery) { return 6_000 - lengthPenalty }
        if let gaps = subsequenceGaps(lowerName, lowerQuery) { return 4_000 - gaps * 10 - lengthPenalty }
        return nil
    }

    /// Where the query starts, if it starts right after a separator — `.`, `:`, `_`, `-`,
    /// `/`, a space, or a lowercase-to-uppercase hump inside a camel-cased name.
    static func boundaryPrefixIndex(_ name: String, _ query: String) -> Int? {
        let characters = Array(name)
        let target = Array(query)
        guard !target.isEmpty, characters.count >= target.count else { return nil }
        let separators: Set<Character> = [".", ":", "_", "-", "/", " ", "(", "<"]

        var index = 1
        while index <= characters.count - target.count {
            let previous = characters[index - 1]
            let current = characters[index]
            // A separator, or a camelCase hump: `Length` inside `NSStringLength` is where a
            // word begins, even though no punctuation says so.
            let isHump = current.isUppercase && (previous.isLowercase || previous.isNumber)
            if separators.contains(previous) || isHump {
                if Array(characters[index..<(index + target.count)]) == target { return index }
            }
            index += 1
        }
        return nil
    }

    /// Number of skipped characters when the query appears in order but not together;
    /// nil when it does not appear at all.
    static func subsequenceGaps(_ name: String, _ query: String) -> Int? {
        var gaps = 0
        var run = false
        var nameIndex = name.startIndex
        for character in query {
            var advanced = false
            while nameIndex < name.endIndex {
                let current = name[nameIndex]
                nameIndex = name.index(after: nameIndex)
                if current == character {
                    advanced = true
                    if !run { run = true } 
                    break
                }
                gaps += 1
                run = false
            }
            if !advanced { return nil }
        }
        return gaps
    }

    /// The whole library's candidates in the order a person should see them. Ties break on
    /// name length, then name, then docset, so the same query always gives the same list.
    public static func rank(_ candidates: [(docset: Docset, entry: IndexEntry)], query: String, limit: Int) -> [Match] {
        var matches: [Match] = []
        matches.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard let score = score(name: candidate.entry.name, query: query) else { continue }
            matches.append(Match(docset: candidate.docset, entry: candidate.entry, score: score))
        }
        matches.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.entry.name.count != b.entry.name.count { return a.entry.name.count < b.entry.name.count }
            if a.entry.name != b.entry.name { return a.entry.name < b.entry.name }
            if a.docset.name != b.docset.name { return a.docset.name < b.docset.name }
            return a.entry.path < b.entry.path
        }
        return limit > 0 ? Array(matches.prefix(limit)) : matches
    }
}
