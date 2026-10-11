public enum MatchKind: String, Sendable, Codable {
    case exact, alias, fuzzy
}

public struct ExerciseMatch: Sendable, Equatable {
    public let exerciseId: String
    public let kind: MatchKind
    public let score: Double
}

public struct ExerciseMatcher: Sendable {
    private let entries: [(id: String, name: String, tokens: Set<String>, aliases: Set<String>, length: Int)]
    public let minimumScore: Double

    public init(library: [Exercise], minimumScore: Double = 0.6) {
        self.minimumScore = minimumScore
        self.entries = library.map { ex in
            let name = Self.normalize(ex.name)
            return (ex.id, name, Self.tokens(name), Set(ex.aliases.map(Self.normalize)), name.count)
        }
    }

    public func match(_ raw: String) -> ExerciseMatch? {
        let name = Self.normalize(raw)
        if let hit = entries.first(where: { $0.name == name }) {
            return ExerciseMatch(exerciseId: hit.id, kind: .exact, score: 1)
        }
        if let hit = entries.first(where: { $0.aliases.contains(name) }) {
            return ExerciseMatch(exerciseId: hit.id, kind: .alias, score: 1)
        }
        let query = Self.tokens(name)
        typealias Scored = (entry: (id: String, name: String, tokens: Set<String>, aliases: Set<String>, length: Int), score: Double)
        let scored: [Scored] = entries.map { entry -> Scored in
            let score: Double = Self.jaccard(query, entry.tokens)
            return (entry: entry, score: score)
        }
        let candidates: [Scored] = scored.filter { $0.score >= minimumScore }
        guard let topScore = candidates.map(\.score).max() else { return nil }
        let topCandidates = candidates.filter { $0.score == topScore }
        // A tied best score is ambiguous - let the app ask the user rather than guessing.
        guard topCandidates.count == 1, let best = topCandidates.first else { return nil }
        return ExerciseMatch(exerciseId: best.entry.id, kind: .fuzzy, score: best.score)
    }

    public static func normalize(_ s: String) -> String {
        s.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    static func tokens(_ normalized: String) -> Set<String> {
        Set(normalized.split(separator: " ").map { token in
            token.count > 3 && token.hasSuffix("s") ? String(token.dropLast()) : String(token)
        })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }
}
