import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// The curated Fitbod alias table (`Resources/fitbod-aliases.json`) must only point at real library ids.
@Suite struct AliasTableTests {
    private func resource(_ name: String) throws -> URL {
        try #require(Bundle.main.url(forResource: name, withExtension: "json"))
    }

    private func aliases() throws -> [String: String?] {
        try JSONDecoder().decode([String: String?].self, from: Data(contentsOf: resource("fitbod-aliases")))
    }

    @Test func tableIsNotEmpty() throws {
        #expect(try aliases().count >= 100)
    }

    @Test func everyValueIsNullOrALibraryId() throws {
        let library = try ExerciseLibrary.load(from: resource("exercises"))
        let unknown = try aliases().compactMap { name, id in
            id.flatMap { library.exercise($0) == nil ? "\(name) -> \($0)" : nil }
        }
        #expect(unknown.isEmpty, "Alias ids missing from exercises.json: \(unknown)")
    }

    @Test func noDuplicateKeysAfterNormalization() throws {
        // JSONDecoder silently keeps one of two identical keys, so count the raw keys in the file too.
        let text = try String(contentsOf: resource("fitbod-aliases"), encoding: .utf8)
        let rawKeys = text.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let end = trimmed.range(of: "\":") else { return nil }
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end.lowerBound])
        }
        let normalized = Set(rawKeys.map(ExerciseMatcher.normalize))
        #expect(rawKeys.count == (try aliases().count))
        #expect(normalized.count == rawKeys.count)
    }

    @Test func plannedExamplesResolveAsCurated() throws {
        let table = try aliases()
        #expect(table["Lat Pulldown"] == .some("0198"))
        #expect(table["Cable Face Pull"] == .some("0203"))
        #expect(table["Machine Shoulder Press"] == .some("0603"))
        #expect(table["Clam"] == .some(nil))
        #expect(table["Handle Band Row"] == .some(nil))
    }
}
