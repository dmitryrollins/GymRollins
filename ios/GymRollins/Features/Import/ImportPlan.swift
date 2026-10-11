import Foundation
import GymCore
import GymData

/// Curated per-app exercise name → library id tables bundled as `<source>-aliases.json`
/// (`null` = create a custom exercise).
enum ImportAliases {
    static func resourceName(for source: ImportSource) -> String {
        switch source {
        case .fitbod: "fitbod-aliases"
        case .strong: "strong-aliases"
        case .hevy: "hevy-aliases"
        case .fitNotes: "fitnotes-aliases"
        }
    }

    static func load(_ source: ImportSource, bundle: Bundle = .main) throws -> [String: String?] {
        guard let url = bundle.url(forResource: resourceName(for: source), withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([String: String?].self, from: Data(contentsOf: url))
    }
}

/// The curated Fitbod table (kept for existing callers).
enum FitbodAliases {
    static func load(bundle: Bundle = .main) throws -> [String: String?] {
        try ImportAliases.load(.fitbod, bundle: bundle)
    }
}

/// What a parsed export would import: how every distinct exercise name resolves, plus headline stats.
/// Pure value — built once after parsing, shown on the import result screen, then handed to `ImportService`.
struct ImportPlan: Sendable {
    enum Resolution: Hashable, Sendable {
        /// Use this library (or existing custom) exercise.
        case library(String)
        /// Create (or reuse) a custom exercise with the exported name.
        case custom
        /// The user must pick; `suggestion` is a fuzzy match to confirm, nil when nothing matched.
        case needsChoice(suggestion: String?)
    }

    struct Stats: Equatable, Sendable {
        let workouts: Int
        let sets: Int
        let warmupSets: Int
        let dateRange: ClosedRange<Date>?
        let rowErrors: [ImportRowError]
    }

    let result: WorkoutImportResult
    /// Distinct exercise names in order of first appearance.
    let names: [String]
    let resolutions: [String: Resolution]
    let stats: Stats

    func resolved(_ name: String) -> Resolution {
        resolutions[name] ?? .needsChoice(suggestion: nil)
    }

    /// Names the user still has to confirm or pick, in file order.
    var needsChoice: [String] {
        names.filter { if case .needsChoice = resolved($0) { true } else { false } }
    }

    /// Resolution order per name: alias table (non-null id → library, null → custom), then the matcher's
    /// exact/alias hit on the English names, then an exact (normalized, unambiguous) other-language name from wger
    /// (`ExerciseLibrary.exerciseId(forOtherName:)`), then an unambiguous fuzzy hit as a suggestion, else unmatched.
    static func make(result: WorkoutImportResult, library: ExerciseLibrary, aliases: [String: String?],
                     matcher: ExerciseMatcher) -> ImportPlan {
        let normalizedAliases = Dictionary(aliases.map { (ExerciseMatcher.normalize($0.key), $0.value) },
                                           uniquingKeysWith: { first, _ in first })
        let names = result.workouts.flatMap(\.entries).map(\.exerciseName)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let resolutions = Dictionary(uniqueKeysWithValues: names.map { name in
            (name, resolve(name, library: library, aliases: normalizedAliases, matcher: matcher))
        })
        let sets = result.workouts.flatMap(\.entries).reduce(0) { $0 + $1.sets.count }
        let dates = result.workouts.map(\.startedAt)
        let range = dates.min().flatMap { low in dates.max().map { low...$0 } }
        let stats = Stats(workouts: result.workouts.count, sets: sets, warmupSets: result.warmupSetCount,
                          dateRange: range, rowErrors: result.rowErrors)
        return ImportPlan(result: result, names: names, resolutions: resolutions, stats: stats)
    }

    private static func resolve(_ name: String, library: ExerciseLibrary, aliases: [String: String?],
                                matcher: ExerciseMatcher) -> Resolution {
        if let alias = aliases[ExerciseMatcher.normalize(name)] {
            guard let id = alias else { return .custom }
            if library.exercise(id) != nil { return .library(id) }
            // A stale alias id falls through to the matcher rather than importing an unknown exercise.
        }
        let match = matcher.match(name)
        if let match, match.kind != .fuzzy { return .library(match.exerciseId) }
        if let id = library.exerciseId(forOtherName: name) { return .library(id) }
        return .needsChoice(suggestion: match?.exerciseId)
    }
}
