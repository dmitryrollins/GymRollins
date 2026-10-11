import GymCore
import Testing
@testable import GymRollins

@Suite struct ImportedExerciseTraitsTests {
    @Test(arguments: [
        ("Handle Band Row", "band", "back"), ("Kettlebell Halo", "kettlebell", "shoulders"),
        ("Machine Leg Press", "leverage machine", "upper legs"), ("Clam", "body weight", "upper legs"),
        ("Behind the Back Cable Bicep Curl", "cable", "upper arms"), ("Prone T's", "body weight", "waist"),
        ("Floor Press", "body weight", "chest"), ("Toe Touchers", "body weight", "waist")
    ])
    func infersEquipmentAndBodyPart(name: String, equipment: String, bodyPart: String) {
        #expect(ImportedExerciseTraits.equipment(for: name) == equipment)
        #expect(ImportedExerciseTraits.bodyPart(for: name) == bodyPart)
    }

    private func set(reps: Int, sec: Int? = nil, distance: Double? = nil) -> ImportedSet {
        // ImportedSet has no public init: build one through the importer.
        let csv = """
        Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier
        2026-01-05 18:00:00 +0000,X,\(reps),0.0,\(sec ?? 0),\(distance ?? 0),0.0,0.0,false,,1.0
        """
        // swiftlint:disable:next force_try
        return try! FitbodImporter.parse(csv).workouts[0].entries[0].sets[0]
    }

    @Test func modeIsCardioOnlyForTimedOrDistanceSetsWithoutReps() {
        #expect(ImportedExerciseTraits.mode(for: [set(reps: 0, sec: 600)]) == .cardio)
        #expect(ImportedExerciseTraits.mode(for: [set(reps: 0, distance: 400)]) == .cardio)
        #expect(ImportedExerciseTraits.mode(for: [set(reps: 12), set(reps: 10)]) == .reps)
        #expect(ImportedExerciseTraits.mode(for: [set(reps: 10, sec: 30)]) == .reps)
    }
}
