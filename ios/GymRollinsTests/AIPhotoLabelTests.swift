import Foundation
import GymCore
import Testing
@testable import GymRollins

/// AI-generated exercise photos carry an "AI" badge whose explanation says they may be wrong.
@MainActor
@Suite struct AIPhotoLabelTests {
    private let bench = Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell",
                                 target: "pectorals")

    private struct FixedProvider: ExerciseMediaProvider {
        let source: ExerciseMedia.Source
        func media(for exercise: Exercise) -> ExerciseMedia? {
            ExerciseMedia(photos: [URL(string: "https://photos.uitest.invalid/\(exercise.id)/0.jpg")!],
                          animation: nil, source: source)
        }
    }

    private struct NoMedia: ExerciseMediaProvider {
        func media(for exercise: Exercise) -> ExerciseMedia? { nil }
    }

    @Test func ownMediaIsAIGeneratedStockPhotosAreNot() {
        #expect(ExerciseMedia(photos: [], animation: nil, source: .own).isAIGenerated)
        #expect(!ExerciseMedia(photos: [], animation: nil, source: .freeExerciseDB).isAIGenerated)
    }

    @Test func modelFlagsAIPhotosAndClearsTheFlagOtherwise() async {
        let model = ExercisePhotoModel()
        await model.load(bench, service: ExerciseMediaService(provider: FixedProvider(source: .own),
                                                              loader: StubPhotoLoader()), maxPixelSize: 100)
        #expect(!model.frames.isEmpty)
        #expect(model.isAIGenerated)

        await model.load(bench, service: ExerciseMediaService(provider: FixedProvider(source: .freeExerciseDB),
                                                              loader: StubPhotoLoader()), maxPixelSize: 100)
        #expect(!model.isAIGenerated)

        await model.load(bench, service: ExerciseMediaService(provider: FixedProvider(source: .own),
                                                              loader: StubPhotoLoader()), maxPixelSize: 100)
        await model.load(bench, service: ExerciseMediaService(provider: NoMedia(), loader: StubPhotoLoader()),
                         maxPixelSize: 100)
        #expect(!model.isAIGenerated, "no photo, no badge")
    }

    @Test func noticeSaysItMayBeWrong() {
        #expect(AIPhotoNotice.title == "AI-generated image")
        #expect(AIPhotoNotice.message.contains("not an accurate representation"))
        #expect(AIPhotoNotice.message.contains("can be wrong"))
    }
}
