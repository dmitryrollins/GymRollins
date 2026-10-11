import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// The curated Strong / Hevy / FitNotes alias tables (`Resources/<app>-aliases.json`) must only point at real
/// library ids, have no keys that collide after normalization, and cover each app's common exercise names.
@Suite struct OtherAppsAliasTableTests {
    static let sources: [ImportSource] = [.strong, .hevy, .fitNotes]

    private func url(_ source: ImportSource) throws -> URL {
        try #require(Bundle.main.url(forResource: ImportAliases.resourceName(for: source), withExtension: "json"))
    }

    @Test(arguments: sources)
    func tableCoversTheCommonNames(_ source: ImportSource) throws {
        let table = try ImportAliases.load(source)
        #expect(table.count >= 40)
        #expect(table.values.filter { $0 != nil }.count >= 35)
    }

    @Test(arguments: sources)
    func everyValueIsNullOrALibraryId(_ source: ImportSource) throws {
        let library = try ImportFixtures.library()
        let unknown = try ImportAliases.load(source).compactMap { name, id in
            id.flatMap { library.exercise($0) == nil ? "\(name) -> \($0)" : nil }
        }
        #expect(unknown.isEmpty, "Alias ids missing from exercises.json: \(unknown)")
    }

    @Test(arguments: sources)
    func noDuplicateKeysAfterNormalization(_ source: ImportSource) throws {
        let text = try String(contentsOf: url(source), encoding: .utf8)
        let rawKeys = text.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let end = trimmed.range(of: "\":") else { return nil }
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end.lowerBound])
        }
        #expect(rawKeys.count == (try ImportAliases.load(source).count))
        #expect(Set(rawKeys.map(ExerciseMatcher.normalize)).count == rawKeys.count)
    }

    @Test func fitbodTableStillLoadsThroughTheSharedLoader() throws {
        #expect(try ImportAliases.load(.fitbod) == FitbodAliases.load())
    }
}
