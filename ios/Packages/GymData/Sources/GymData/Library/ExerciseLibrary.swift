import Foundation
import GymCore

/// Immutable, searchable exercise catalogue (bundled + custom), optionally with names in other languages (from
/// wger, `exercise-names-i18n.json`) that search and import matching also accept. Displayed names stay English.
public struct ExerciseLibrary: Sendable {
    public let exercises: [Exercise]
    private let byId: [String: Exercise]
    private let searchKeys: [String: String]
    /// Library id -> other-language names, as given (for display).
    private let otherNamesById: [String: [String]]
    /// Library id -> search keys of its other-language names (normalized, diacritics folded).
    private let otherSearchKeys: [String: [String]]
    /// Library id -> other-language names that may resolve imports (a subset of `otherNamesById`).
    private let importNamesById: [String: [String]]
    /// Normalized import name -> library id, only for names that point at exactly one exercise.
    private let idByOtherName: [String: String]

    /// `importNames`: the other names that may resolve imported exercises automatically (default: all of
    /// `otherNames`); names wger also uses for another exercise stay search-only.
    public init(exercises: [Exercise], otherNames: [String: [String]] = [:], importNames: [String: [String]]? = nil) {
        self.exercises = exercises
        let byId = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.byId = byId
        self.searchKeys = Dictionary(exercises.map { ($0.id, Self.key($0.name)) }, uniquingKeysWith: { first, _ in first })
        let known = otherNames.filter { byId[$0.key] != nil && !$0.value.isEmpty }
        self.otherNamesById = known
        self.otherSearchKeys = known.mapValues { $0.map(Self.foldedKey) }
        let importable = (importNames ?? otherNames).filter { byId[$0.key] != nil && !$0.value.isEmpty }
        self.importNamesById = importable
        var owners: [String: Set<String>] = [:]
        for (id, names) in importable {
            for name in names { owners[ExerciseMatcher.normalize(name), default: []].insert(id) }
        }
        self.idByOtherName = owners.compactMapValues { $0.count == 1 ? $0.first : nil }.filter { !$0.key.isEmpty }
    }

    public static func load(from url: URL, otherNames: [String: [String]] = [:],
                            importNames: [String: [String]]? = nil) throws -> ExerciseLibrary {
        ExerciseLibrary(exercises: try JSONDecoder().decode([Exercise].self, from: Data(contentsOf: url)),
                        otherNames: otherNames, importNames: importNames)
    }

    public func merging(custom: [Exercise]) -> ExerciseLibrary {
        ExerciseLibrary(exercises: custom + exercises.filter { !$0.isCustom }, otherNames: otherNamesById,
                        importNames: importNamesById)
    }

    public func exercise(_ id: String) -> Exercise? { byId[id] }

    /// The exercise's names in other languages (empty for most exercises and all custom ones).
    public func otherNames(for id: String) -> [String] { otherNamesById[id] ?? [] }

    /// The library exercise whose other-language name equals `raw` exactly after normalization (case, punctuation
    /// and spacing; diacritics count), or nil when none or several have it. Import matching uses this after the
    /// English name and the app-specific alias tables.
    public func exerciseId(forOtherName raw: String) -> String? {
        idByOtherName[ExerciseMatcher.normalize(raw)]
    }

    public var bodyParts: [String] { Array(Set(exercises.map(\.bodyPart))).sorted() }
    public var equipment: [String] { Array(Set(exercises.map(\.equipment))).sorted() }

    /// All query words must appear in the English name (order-free, spaces ignored within words), or all in one of
    /// the exercise's other-language names (diacritic-insensitive: "bankdrucken" finds "Bankdrücken").
    public func search(query: String, bodyPart: String? = nil, equipment: String? = nil) -> [Exercise] {
        let words = Self.key(query).split(separator: " ").map(String.init)
        let foldedWords = Self.foldedKey(query).split(separator: " ").map(String.init)
        return exercises.filter { ex in
            guard (bodyPart == nil || ex.bodyPart == bodyPart) && (equipment == nil || ex.equipment == equipment) else {
                return false
            }
            if Self.contains(all: words, in: searchKeys[ex.id] ?? "") { return true }
            guard !foldedWords.isEmpty, let others = otherSearchKeys[ex.id] else { return false }
            return others.contains { Self.contains(all: foldedWords, in: $0) }
        }
    }

    private static func contains(all words: [String], in key: String) -> Bool {
        let joined = key.replacingOccurrences(of: " ", with: "")
        return words.allSatisfy { key.contains($0) || joined.contains($0) }
    }

    static func key(_ s: String) -> String { ExerciseMatcher.normalize(s) }

    static func foldedKey(_ s: String) -> String {
        ExerciseMatcher.normalize(s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil))
    }
}
