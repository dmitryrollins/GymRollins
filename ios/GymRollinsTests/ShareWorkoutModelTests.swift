import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct ShareWorkoutModelTests {
    private let library = ExerciseLibrary(exercises: [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
        Exercise(id: "custom-1", name: "sled push", bodyPart: "upper legs", equipment: "other", target: "quads", isCustom: true),
    ])
    private let link = WorkoutLink(host: nil)

    private func source(_ id: String) -> SharedWorkout.Source {
        SharedWorkout.Source(item: RoutineExercise(exerciseId: id, sets: 3, reps: 10))
    }

    @Test func makesALinkAndACode() {
        let model = ShareWorkoutModel.make(sources: [source("0025")], library: library, link: link)
        #expect(model.url?.absoluteString == "gymrollins://w#1.0025_3_10")
        #expect(model.qrCode != nil)
        #expect(model.leftOutNotice == nil)
        #expect(model.cutOffNotice == nil)
        #expect(!model.nothingToSend)
    }

    @Test func namesWhatIsLeftOut() {
        let model = ShareWorkoutModel.make(sources: [source("0025"), source("custom-1")], library: library, link: link)
        #expect(model.url?.absoluteString == "gymrollins://w#1.0025_3_10")
        #expect(model.leftOutNotice == "Left out, because it's your own exercise: Sled Push")
    }

    @Test func aPluralNotice() {
        let library = ExerciseLibrary(exercises: [
            Exercise(id: "0025", name: "bench", bodyPart: "chest", equipment: "barbell", target: "pectorals"),
            Exercise(id: "custom-1", name: "sled push", bodyPart: "back", equipment: "other", target: "lats", isCustom: true),
            Exercise(id: "custom-2", name: "rope pull", bodyPart: "back", equipment: "other", target: "lats", isCustom: true),
        ])
        let model = ShareWorkoutModel.make(sources: [source("0025"), source("custom-1"), source("custom-2")],
                                           library: library, link: link)
        #expect(model.leftOutNotice == "Left out, because they're your own exercises: Sled Push, Rope Pull")
    }

    @Test func onlyCustomExercisesLeaveNothingToSend() {
        let model = ShareWorkoutModel.make(sources: [source("custom-1")], library: library, link: link)
        #expect(model.nothingToSend)
        #expect(model.url == nil)
        #expect(model.qrCode == nil)
    }

    @Test func saysWhenOnlyTheFirstTwentyWent() {
        let sources = (0..<21).map { source(String(format: "%04d", $0)) }
        let model = ShareWorkoutModel.make(sources: sources, library: library, link: link)
        #expect(model.cutOffNotice == "Only the first 20 exercises are in this link.")
    }

    /// Decision 5: a library exercise that can't go in a link would vanish from a shared workout without explanation.
    @Test func everyRealLibraryExerciseCanBeShared() throws {
        let url = try #require(Bundle.main.url(forResource: "exercises", withExtension: "json"))
        let real = try ExerciseLibrary.load(from: url)
        let draft = SharedWorkout.make(from: real.exercises.map { source($0.id) })
        #expect(draft.leftOutIds.isEmpty)
    }
}
