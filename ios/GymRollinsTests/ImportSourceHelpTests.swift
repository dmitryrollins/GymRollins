import Foundation
import GymCore
import Testing
@testable import GymRollins

#if DEBUG
/// The UI tests import the embedded `ImportFixture` strings; the unit tests import `Fixtures/*.csv`. They must match.
@Suite struct ImportFixtureSyncTests {
    private final class BundleToken {}

    @Test(arguments: ImportSource.allCases)
    func embeddedFixtureMatchesFile(_ source: ImportSource) throws {
        let name = ImportFixture.fileName(for: source)
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: (name as NSString).deletingPathExtension,
                                                                 withExtension: "csv"))
        let file = try String(contentsOf: url, encoding: .utf8)
        // Foundation may drop the file's BOM when decoding; the parsers accept either.
        let trim: (String) -> String = { $0.trimmingCharacters(in: .newlines.union(CharacterSet(charactersIn: "\u{FEFF}"))) }
        #expect(trim(ImportFixture.csv(for: source)) == trim(file))
        #expect(WorkoutImporters.detect(ImportFixture.csv(for: source)) == source)
    }

    @Test func launchOptionPicksTheFixtureSource() {
        #expect(LaunchOptions(arguments: ["-importFixture", "hevy"]).importFixtureSource == .hevy)
        #expect(LaunchOptions(arguments: ["-importFixture", "fitNotes"]).importFixtureSource == .fitNotes)
        #expect(LaunchOptions(arguments: ["-importFixture"]).importFixtureSource == .fitbod)
        #expect(LaunchOptions(arguments: ["-importFixture", "-uiTesting"]).importFixtureSource == .fitbod)
    }
}
#endif

@Suite struct ImportSourceHelpTests {
    @Test func everySourceHasHelpAndMapping() {
        #expect(ImportSourceHelp.title(for: nil) == "Auto-detect")
        #expect(ImportSourceHelp.text(for: nil).contains("Strong"))
        for source in ImportSource.allCases {
            #expect(ImportSourceHelp.title(for: source) == source.displayName)
            #expect(ImportSourceHelp.text(for: source).hasPrefix("In \(source.displayName):"))
            #expect(!ImportSourceHelp.mapping(for: source).isEmpty)
        }
    }

    @Test func errorMessagesNameTheApps() {
        #expect(ImportSourceHelp.message(for: .emptyFile, selected: nil) == "That file is empty.")
        #expect(ImportSourceHelp.message(for: .unrecognizedHeader(["x"]), selected: nil).contains("Fitbod, Strong, Hevy"))
        let strong = ImportSourceHelp.message(for: .unrecognizedHeader(["x"]), selected: .strong)
        #expect(strong.hasPrefix("This doesn't look like a Strong export. Expected columns: Date, Workout Name"))
        let mismatch = ImportSourceHelp.message(for: .sourceMismatch(selected: .strong, detected: .hevy), selected: .strong)
        #expect(mismatch == "This looks like a Hevy export, not Strong. Pick Hevy or Auto-detect.")
    }
}
