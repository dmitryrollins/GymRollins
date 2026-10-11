import Foundation
import GymCore
import Testing
@testable import GymRollins

@Suite struct ExerciseMediaProviderTests {
    private func exercise(_ id: String = "0025", image: String? = nil, gif: String? = nil) -> Exercise {
        Exercise(id: id, name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals",
                 image: image, gif: gif)
    }

    private let mappingJSON = Data("""
    {"source":"yuhonas/free-exercise-db","commit":"abc","baseURL":"https://cdn.example.com/fedb@abc/exercises/",
     "photos":{"0025":["Barbell_Bench_Press_-_Medium_Grip/0.jpg","Barbell_Bench_Press_-_Medium_Grip/1.jpg"],
               "0070":["Front_Squat_(Clean_Grip)/0.jpg"]}}
    """.utf8)

    // MARK: free-exercise-db mapping

    @Test func mappingLookupBuildsPinnedURLsInOrder() throws {
        let provider = try FreeExerciseDBPhotoProvider(data: mappingJSON)
        let media = try #require(provider.media(for: exercise()))
        #expect(media.source == .freeExerciseDB)
        #expect(media.photos.map(\.absoluteString) == [
            "https://cdn.example.com/fedb@abc/exercises/Barbell_Bench_Press_-_Medium_Grip/0.jpg",
            "https://cdn.example.com/fedb@abc/exercises/Barbell_Bench_Press_-_Medium_Grip/1.jpg"
        ])
        #expect(media.animation == nil)
    }

    @Test func mappingKeepsUpstreamFolderNamesWithParentheses() throws {
        let provider = try FreeExerciseDBPhotoProvider(data: mappingJSON)
        let url = try #require(provider.media(for: exercise("0070"))?.photos.first)
        #expect(url.host() == "cdn.example.com")
        #expect(url.absoluteString == "https://cdn.example.com/fedb@abc/exercises/Front_Squat_(Clean_Grip)/0.jpg")
    }

    @Test func unmappedExerciseHasNoMedia() throws {
        let provider = try FreeExerciseDBPhotoProvider(data: mappingJSON)
        #expect(provider.media(for: exercise("9999")) == nil)
    }

    @Test func mappingRejectsNonHTTPSBaseURL() {
        let json = Data(#"{"baseURL":"http://cdn.example.com/","photos":{}}"#.utf8)
        #expect(throws: (any Error).self) { try FreeExerciseDBPhotoProvider(data: json) }
    }

    @Test func mappingDropsTraversalPaths() throws {
        let json = Data(#"{"baseURL":"https://cdn.example.com/x/","photos":{"1":["../../evil/0.jpg"],"2":["A/0.jpg"]}}"#.utf8)
        let provider = try FreeExerciseDBPhotoProvider(data: json)
        #expect(provider.media(for: exercise("1")) == nil)
        #expect(provider.media(for: exercise("2")) != nil)
    }

    @Test func bundledMappingCoversTheOwnersBenchPress() throws {
        let provider = try #require(FreeExerciseDBPhotoProvider.bundled())
        let media = try #require(provider.media(for: exercise("0025")))
        #expect(media.photos.count == 2)
        #expect(media.photos.allSatisfy { $0.scheme == "https" && $0.host() == "cdn.jsdelivr.net" })
        #expect(media.photos[0].absoluteString.contains("yuhonas/free-exercise-db@"))
    }

    // MARK: Own media on the exercise record

    @Test func recordProviderUsesHTTPSImageAndGif() throws {
        let media = try #require(ExerciseRecordMediaProvider().media(for: exercise(
            image: "https://media.example.com/0025.jpg", gif: "https://media.example.com/0025.gif")))
        #expect(media.source == .own)
        #expect(media.photos.map(\.absoluteString) == ["https://media.example.com/0025.jpg"])
        #expect(media.animation?.absoluteString == "https://media.example.com/0025.gif")
    }

    @Test func recordProviderIgnoresRelativeOrInsecureValues() {
        let provider = ExerciseRecordMediaProvider()
        #expect(provider.media(for: exercise(image: "0025.jpg")) == nil, "opengym-style bare file names never load")
        #expect(provider.media(for: exercise(image: "http://media.example.com/a.jpg")) == nil)
        #expect(provider.media(for: exercise()) == nil)
    }

    // MARK: Resolution order

    @Test func ownMediaWinsOverFreeExerciseDBPhotos() throws {
        let chain = ChainedMediaProvider([ExerciseRecordMediaProvider(), try FreeExerciseDBPhotoProvider(data: mappingJSON)])
        let own = chain.media(for: exercise(image: "https://media.example.com/0025.jpg"))
        #expect(own?.source == .own)
        #expect(chain.media(for: exercise())?.source == .freeExerciseDB)
    }

    @Test func noProviderMeansIllustrationFallback() throws {
        let chain = ChainedMediaProvider([ExerciseRecordMediaProvider(), try FreeExerciseDBPhotoProvider(data: mappingJSON)])
        #expect(chain.media(for: exercise("custom-1")) == nil)
        #expect(ChainedMediaProvider([]).media(for: exercise()) == nil)
    }
}
