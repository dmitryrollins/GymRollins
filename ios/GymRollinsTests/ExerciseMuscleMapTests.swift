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

    @Test func theKeyShowsOnlyTheRolesTheMapUses() {
        #expect(ExerciseMuscleMap.keyRoles(MuscleTaxonomy.contributions(for: bench)) == [.target, .secondary])
        let curl = Exercise(id: "c", name: "curl", bodyPart: "upper arms", equipment: "dumbbell", target: "biceps")
        #expect(ExerciseMuscleMap.keyRoles(MuscleTaxonomy.contributions(for: curl)) == [.target])
        // A target the taxonomy doesn't know, on a body part it doesn't know either: only the secondary group shows.
        let odd = Exercise(id: "o", name: "odd", bodyPart: "unknown", equipment: "band", target: "unknown",
                           secondary: ["triceps"])
        let secondaryOnly = MuscleTaxonomy.contributions(for: odd)
        #expect(secondaryOnly.map(\.isPrimary) == [false])
        #expect(ExerciseMuscleMap.keyRoles(secondaryOnly) == [.secondary])
        #expect(ExerciseMuscleMap.keyRoles([]) == [])
    }

    @Test func labelNamesTargetThenSecondary() {
        #expect(ExerciseMuscleMap.label(MuscleTaxonomy.contributions(for: bench))
                == "Works chest; also triceps, shoulders")
    }
}
