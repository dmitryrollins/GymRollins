import GymCore
import Testing
@testable import GymRollins

@Suite struct ExerciseMuscleMapTests {
    private let bench = Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell",
                                 target: "pectorals", secondary: ["triceps", "shoulders"])

    @Test func targetSecondaryAndUntouchedGroups() {
        let contributions = MuscleTaxonomy.contributions(for: bench)
        #expect(MuscleRole.of(.chest, in: contributions) == .target)
        #expect(MuscleRole.of(.triceps, in: contributions) == .secondary)
        #expect(MuscleRole.of(.shoulders, in: contributions) == .secondary)
        #expect(MuscleRole.of(.quads, in: contributions) == .none)
    }

    @Test func cardioWorksNoGroup() {
        let run = Exercise(id: "r", name: "run", bodyPart: "cardio", equipment: "body weight",
                           target: "cardiovascular system", mode: .cardio)
        #expect(MuscleTaxonomy.contributions(for: run).isEmpty)
    }

    @Test func labelNamesTargetThenSecondary() {
        #expect(ExerciseMuscleMap.label(MuscleTaxonomy.contributions(for: bench))
                == "Works chest; also triceps, shoulders")
    }
}
