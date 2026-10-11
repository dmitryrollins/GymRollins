import Foundation
import GymCore
import GymData
import Testing
import UIKit
@testable import GymRollins

private func exercise(_ id: String) -> Exercise {
    Exercise(id: id, name: "exercise \(id)", bodyPart: "chest", equipment: "barbell", target: "pectorals")
}

private let credit = #"""
"title":"Bench Press","author":"Everkinetic","license":"CC-BY-SA 3",
"licenseUrl":"https://creativecommons.org/licenses/by-sa/3.0/deed.en",
"sourceUrl":"https://wger.de/exercise/73/view-base","modified":true
"""#

// MARK: - Photos

@Suite struct WgerPhotoProviderTests {
    private let json = Data("""
    {"source":"wger.de","snapshot":"2026-09-30","apiVersion":"2.8.0-dev.0","photos":{
     "0025":[{"url":"https://wger.de/media/exercise-images/73/Bench-press-1.png",\(credit)},
             {"url":"https://wger.de/media/exercise-images/73/Bench-press-2.png",\(credit)}],
     "0100":[{"url":"http://wger.de/media/exercise-images/1/a.png",\(credit)}],
     "0101":[{"url":"https://evil.example/media/exercise-images/1/a.png",\(credit)}],
     "0102":[{"url":"https://wger.de/media/exercise-images/1/a.png","title":"x","author":" ","license":"CC-BY-SA 4",
              "licenseUrl":"https://creativecommons.org/licenses/by-sa/4.0/","sourceUrl":"https://wger.de/exercise/1/view-base",
              "modified":true}],
     "0103":[{"url":"https://wger.de/media/exercise-images/1/a.png","title":"x","author":"a","license":"CC-BY-SA 4",
              "licenseUrl":"javascript:alert(1)","sourceUrl":"https://wger.de/exercise/1/view-base","modified":true}]
    }}
    """.utf8)

    @Test func mapsCreditedPhotosInOrder() throws {
        let provider = try WgerPhotoProvider(data: json)
        let media = try #require(provider.media(for: exercise("0025")))
        #expect(media.source == .wger)
        #expect(!media.isAIGenerated, "wger photos are not our AI photos: no AI badge")
        #expect(media.photos.map(\.lastPathComponent) == ["Bench-press-1.png", "Bench-press-2.png"])
        #expect(media.credits.count == 2)
        let first = try #require(media.credits.first)
        #expect(first.author == "Everkinetic")
        #expect(first.license == "CC-BY-SA 3")
        #expect(first.title == "Bench Press")
        #expect(first.modified)
        #expect(first.licenseURL?.absoluteString == "https://creativecommons.org/licenses/by-sa/3.0/deed.en")
        #expect(first.sourceURL?.absoluteString == "https://wger.de/exercise/73/view-base")
    }

    @Test func dropsInsecureForeignHostAndUncreditedEntries() throws {
        let provider = try WgerPhotoProvider(data: json)
        #expect(provider.media(for: exercise("0100")) == nil, "plain http")
        #expect(provider.media(for: exercise("0101")) == nil, "only wger.de media")
        #expect(provider.media(for: exercise("0102")) == nil, "no author to credit")
        #expect(provider.media(for: exercise("0103"))?.credits.first?.licenseURL == nil,
                "a non-web link is never offered, the photo still shows with its credit text")
        #expect(provider.media(for: exercise("9999")) == nil)
    }

    @Test func bundledMappingIsWgerOnlyAndCredited() throws {
        let provider = try #require(WgerPhotoProvider.bundled())
        let media = try #require(provider.media(for: exercise("0813")), "triceps dip between benches: Everkinetic")
        #expect(media.photos.allSatisfy { $0.scheme == "https" && $0.host() == "wger.de" })
        #expect(media.credits.allSatisfy { $0.author == "Everkinetic" && $0.license == "CC-BY-SA 3" })
    }

    @Test func freeExerciseDBComesBeforeWgerWhichOnlyFillsGaps() throws {
        let service = ExerciseMediaService.make(options: LaunchOptions(arguments: [], environment: [:]),
                                                info: ["PHOTO_HOSTING": "bundle"])
        let chain = try #require(service.provider as? ChainedMediaProvider)
        let fedb = try #require(chain.providers.firstIndex { $0 is FreeExerciseDBPhotoProvider })
        let wger = try #require(chain.providers.firstIndex { $0 is WgerPhotoProvider })
        #expect(fedb < wger)
        #expect(wger == chain.providers.count - 1, "wger is the last photo source before the illustration")
        // Bench press has both: free-exercise-db is shown, wger is the fallback candidate.
        #expect(chain.media(for: exercise("0025"))?.source == .freeExerciseDB)
        #expect(chain.candidates(for: exercise("0025")).map(\.source) == [.freeExerciseDB, .wger])
        #expect(chain.media(for: exercise("0813"))?.source == .wger, "no other photo: wger fills the gap")
    }
}

// MARK: - Photo model

private struct AnyLoader: ExercisePhotoLoading {
    func image(for url: URL, maxPixelSize: CGFloat?) async throws -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    }
}

private struct OneProvider: ExerciseMediaProvider {
    let media: ExerciseMedia
    func media(for exercise: Exercise) -> ExerciseMedia? { media }
}

@MainActor
@Suite struct WgerPhotoModelTests {
    private let urls = [URL(string: "https://wger.de/media/a.png")!, URL(string: "https://wger.de/media/b.png")!]
    private let photoCredit = PhotoCredit(title: "Butterfly", author: "Everkinetic", license: "CC-BY-SA 3",
                                          licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/3.0/"),
                                          sourceURL: URL(string: "https://wger.de/exercise/135/view-base"), modified: true)

    @Test func wgerFramesCarryCreditsAndNeutralLabels() async {
        let media = ExerciseMedia(photos: urls, animation: nil, source: .wger, credits: [photoCredit, photoCredit])
        let model = ExercisePhotoModel()
        await model.load(exercise("0596"), service: ExerciseMediaService(provider: OneProvider(media: media),
                                                                        loader: AnyLoader()), maxPixelSize: nil)
        #expect(model.source == .wger)
        #expect(!model.isAIGenerated)
        #expect(model.credit == photoCredit)
        #expect(model.frames.map { model.label(for: $0) } == ["Photo 1 of 2", "Photo 2 of 2"],
                "wger images aren't guaranteed start/end positions")
    }

    @Test func freeExerciseDBFramesKeepPositionLabelsAndHaveNoCredit() async {
        let media = ExerciseMedia(photos: urls, animation: nil, source: .freeExerciseDB)
        let model = ExercisePhotoModel()
        await model.load(exercise("0025"), service: ExerciseMediaService(provider: OneProvider(media: media),
                                                                        loader: AnyLoader()), maxPixelSize: nil)
        #expect(model.credit == nil)
        #expect(model.frames.map { model.label(for: $0) } == ["Start position", "End position"])
    }

    @Test func captionTextNamesAuthorAndLicense() {
        #expect(photoCredit.caption == "Photo: Everkinetic · CC-BY-SA 3")
    }
}

// MARK: - Other-language names

@Suite struct ExerciseNamesI18nTests {
    private let json = Data("""
    {"source":"wger.de","snapshot":"2026-09-30","apiVersion":"2.8.0-dev.0","exercises":{
     "0025":{"names":{"de":[{"n":"Bankdrücken LH","a":"sistab2","l":"CC-BY-SA 3"}],
                      "es":[{"n":"Press de Banca","a":"wgerjhn","l":"CC-BY-SA 4"},
                            {"n":"Pecho","a":"wgerjhn","l":"CC-BY-SA 4","s":true}]},
             "sources":["https://wger.de/exercise/73/view-base","https://wger.de/exercise/2700/view-base",
                        "javascript:alert(1)"]},
     "0026":{"names":{"de":[{"n":" ","a":"x","l":"CC0"}]},"sources":["https://wger.de/exercise/1/view-base"]}
    }}
    """.utf8)

    @Test func parsesNamesPerLanguageWithCredits() throws {
        let catalog = try ExerciseNamesI18n(data: json)
        #expect(catalog.names(for: "0025") == ["Bankdrücken LH", "Press de Banca", "Pecho"])
        #expect(catalog.importNames["0025"] == ["Bankdrücken LH", "Press de Banca"], "search-only names never import")
        let entry = try #require(catalog.entry(for: "0025"))
        #expect(entry.languages.map(\.code) == ["de", "es"])
        #expect(entry.languages.first?.names.first?.author == "sistab2")
        #expect(entry.sources.map(\.absoluteString) == ["https://wger.de/exercise/73/view-base",
                                                        "https://wger.de/exercise/2700/view-base"],
                "every contributing wger entry is linked; non-web links are dropped")
        #expect(catalog.entry(for: "0026") == nil, "blank names are dropped")
        #expect(catalog.searchNames["0025"] == ["Bankdrücken LH", "Press de Banca", "Pecho"])
    }

    @Test func bundledCatalogLeavesOutReviewedMistranslations() throws {
        let catalog = try #require(ExerciseNamesI18n.bundled())
        #expect(!catalog.names(for: "0652").contains("Flexões de braço"), "Portuguese push-ups is not a pull-up")
        #expect(!catalog.names(for: "0126").contains("Kurzhantel-Unterarmcurl"))
        let library = try ExerciseLibrary.load(from: #require(Bundle.main.url(forResource: "exercises", withExtension: "json")),
                                               otherNames: catalog.searchNames)
        #expect(library.exerciseId(forOtherName: "Flexões de braço") == nil)
        let importing = try ExerciseLibrary.load(
            from: #require(Bundle.main.url(forResource: "exercises", withExtension: "json")),
            otherNames: catalog.searchNames, importNames: catalog.importNames)
        #expect(importing.exerciseId(forOtherName: "Abdominales") == nil, "wger also calls sit-ups this")
        #expect(importing.search(query: "Abdominales").map(\.id).contains("0274"), "still searchable")
        #expect(importing.exerciseId(forOtherName: "Bankdrücken LH") == "0025")
        #expect(catalog.entry(for: "0594")?.sources.map(\.absoluteString) == ["https://wger.de/exercise/590/view-base"],
                "credits link the wger entry the names came from")
    }

    @Test func bundledCatalogFeedsTheLibrarySearch() throws {
        let catalog = try #require(ExerciseNamesI18n.bundled())
        #expect(catalog.names(for: "0025").contains("Bankdrücken LH"))
        let library = try ExerciseLibrary.load(from: #require(Bundle.main.url(forResource: "exercises", withExtension: "json")),
                                               otherNames: catalog.searchNames)
        #expect(library.search(query: "Bankdrücken").map(\.id).contains("0025"))
    }
}

// MARK: - Import fallback

@Suite struct OtherLanguageImportTests {
    private func plan(_ names: [String], aliases: [String: String?] = [:],
                      otherNames: [String: [String]]) throws -> ImportPlan {
        let base = try ImportFixtures.library()
        let lib = ExerciseLibrary(exercises: base.exercises, otherNames: otherNames)
        let rows = names.map { "2026-01-05 18:00:00 +0000,\($0),5,60.0,0.0,0.0,0.0,0.0,false,,1.0" }
        let csv = (["Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier"]
            + rows).joined(separator: "\n")
        return ImportPlan.make(result: try FitbodImporter.parse(csv), library: lib, aliases: aliases,
                               matcher: ExerciseMatcher(library: lib.exercises))
    }

    @Test func exactOtherLanguageNameResolvesToTheLibrary() throws {
        let result = try plan(["Bankdrücken LH", "bankdrücken  lh"], otherNames: ["0025": ["Bankdrücken LH"]])
        #expect(result.resolved("Bankdrücken LH") == .library("0025"))
        #expect(result.resolved("bankdrücken  lh") == .library("0025"), "normalized: case and spacing")
    }

    @Test func appAliasTableAndEnglishNamesWinOverOtherLanguageNames() throws {
        let result = try plan(["Bankdrücken LH", "barbell deadlift"],
                              aliases: ["Bankdrücken LH": "0047"],
                              otherNames: ["0025": ["Bankdrücken LH"], "0085": ["barbell deadlift"]])
        #expect(result.resolved("Bankdrücken LH") == .library("0047"), "the app's curated table comes first")
        #expect(result.resolved("barbell deadlift") == .library("0032"), "the English library name comes first")
    }

    @Test func partialOrAmbiguousOtherNamesStayForTheUser() throws {
        let result = try plan(["Bankdrücken", "Latziehen"],
                              otherNames: ["0025": ["Bankdrücken LH"], "0198": ["Latziehen"], "0197": ["Latziehen"]])
        #expect(result.resolved("Bankdrücken") == .needsChoice(suggestion: nil), "no partial matches")
        #expect(result.resolved("Latziehen") == .needsChoice(suggestion: nil), "two exercises share the name")
    }
}
