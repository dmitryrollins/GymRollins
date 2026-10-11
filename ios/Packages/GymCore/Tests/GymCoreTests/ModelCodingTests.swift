import Foundation
import Testing
@testable import GymCore

@Suite struct ModelCodingTests {
    @Test func decodesOpengymExerciseShape() throws {
        let json = """
        {"id":"0025","n":"barbell bench press","bp":"chest","eq":"barbell","tg":"pectorals",
         "sm":["triceps","shoulders"],"st":["Lie on the bench."],"img":"0025.jpg","gif":"0025.gif"}
        """
        let ex = try JSONDecoder().decode(Exercise.self, from: Data(json.utf8))
        #expect(ex.name == "barbell bench press")
        #expect(ex.bodyPart == "chest")
        #expect(ex.secondary == ["triceps", "shoulders"])
        #expect(ex.aliases.isEmpty)
        #expect(ex.isCustom == false)
        #expect(ex.mode == .reps)
    }

    @Test func infersCardioModeFromBodyPart() throws {
        let json = #"{"id":"c1","n":"walking","bp":"cardio","eq":"body weight","tg":"cardiovascular system"}"#
        let ex = try JSONDecoder().decode(Exercise.self, from: Data(json.utf8))
        #expect(ex.mode == .cardio)
    }

    @Test func workoutRoundTrips() throws {
        let set = WorkoutSet(weightKg: 58.967, reps: 10, done: true)
        let entry = WorkoutEntry(exerciseId: "0025", sets: [set])
        let workout = Workout(startedAt: Date(timeIntervalSince1970: 1_790_000_000), name: "Push + Biceps", entries: [entry])
        let data = try JSONEncoder().encode(workout)
        #expect(try JSONDecoder().decode(Workout.self, from: data) == workout)
        #expect(workout.source == .app)
        #expect(set.multiplier == 1)
        #expect(set.warmup == false)
    }

    @Test func settingDoneReturnsNewValue() {
        let set = WorkoutSet(weightKg: 20, reps: 10)
        let done = set.completing(at: Date(timeIntervalSince1970: 10))
        #expect(set.done == false)
        #expect(done.done == true)
        #expect(done.completedAt == Date(timeIntervalSince1970: 10))
        #expect(done.id == set.id)
    }

    /// Re-serializes `encodable` with the given keys removed, to simulate a payload
    /// that omits properties the memberwise init defaults.
    private func minimalJSON(removing keys: [String], from encodable: some Encodable) throws -> Data {
        let data = try JSONEncoder().encode(encodable)
        let object = try JSONSerialization.jsonObject(with: data)
        guard var dict = object as? [String: Any] else {
            Issue.record("Expected a JSON object")
            return data
        }
        keys.forEach { dict.removeValue(forKey: $0) }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    @Test func workoutSetDecodesWithMissingDefaultedKeys() throws {
        let data = try minimalJSON(
            removing: ["sec", "minutes", "distanceM", "done", "warmup", "rir", "rpe", "multiplier", "completedAt"],
            from: WorkoutSet(weightKg: 20, reps: 5)
        )
        let decoded = try JSONDecoder().decode(WorkoutSet.self, from: data)
        #expect(decoded.weightKg == 20)
        #expect(decoded.reps == 5)
        #expect(decoded.done == false)
        #expect(decoded.warmup == false)
        #expect(decoded.multiplier == 1)
        #expect(decoded.sec == nil)
        #expect(decoded.minutes == nil)
        #expect(decoded.distanceM == nil)
        #expect(decoded.rir == nil)
        #expect(decoded.rpe == nil)
        #expect(decoded.completedAt == nil)
    }

    @Test func workoutEntryDecodesWithMissingDefaultedKeys() throws {
        let data = try minimalJSON(removing: ["sets", "note", "supersetGroup"],
                                   from: WorkoutEntry(exerciseId: "bench"))
        let decoded = try JSONDecoder().decode(WorkoutEntry.self, from: data)
        #expect(decoded.exerciseId == "bench")
        #expect(decoded.sets == [])
        #expect(decoded.note == nil)
        #expect(decoded.supersetGroup == nil)
    }

    @Test func workoutDecodesWithMissingDefaultedKeys() throws {
        let full = Workout(startedAt: Date(timeIntervalSince1970: 1_790_000_000), name: "Push + Biceps")
        let data = try minimalJSON(
            removing: ["endedAt", "pausedSeconds", "routineId", "entries", "source", "note"], from: full
        )
        let decoded = try JSONDecoder().decode(Workout.self, from: data)
        #expect(decoded.startedAt == full.startedAt)
        #expect(decoded.name == "Push + Biceps")
        #expect(decoded.pausedSeconds == 0)
        #expect(decoded.entries == [])
        #expect(decoded.source == .app)
        #expect(decoded.endedAt == nil)
        #expect(decoded.note == nil)
    }

    @Test func routineExerciseDecodesWithMissingDefaultedKeys() throws {
        let full = RoutineExercise(exerciseId: "bench", sets: 3, reps: 8)
        let data = try minimalJSON(
            removing: ["repsMin", "sec", "weightKg", "mode", "policy", "incKg", "supersetGroup"], from: full
        )
        let decoded = try JSONDecoder().decode(RoutineExercise.self, from: data)
        #expect(decoded.exerciseId == "bench")
        #expect(decoded.sets == 3)
        #expect(decoded.reps == 8)
        #expect(decoded.mode == .reps)
        #expect(decoded.policy == nil)
    }

    @Test func routineDecodesWithMissingDefaultedKeys() throws {
        let full = Routine(name: "Push Day")
        let data = try minimalJSON(removing: ["emoji", "policy", "paused", "exercises"], from: full)
        let decoded = try JSONDecoder().decode(Routine.self, from: data)
        #expect(decoded.name == "Push Day")
        #expect(decoded.policy == .double)
        #expect(decoded.paused == false)
        #expect(decoded.exercises == [])
    }

    @Test func decodesMuscleGroupFromOpengymKey() throws {
        let json = """
        {"id":"0025","n":"barbell bench press","bp":"chest","eq":"barbell","tg":"pectorals","mg":"chest"}
        """
        let ex = try JSONDecoder().decode(Exercise.self, from: Data(json.utf8))
        #expect(ex.muscleGroup == "chest")
    }

    @Test func muscleGroupDefaultsToNilWhenAbsent() throws {
        let json = #"{"id":"0025","n":"barbell bench press","bp":"chest","eq":"barbell","tg":"pectorals"}"#
        let ex = try JSONDecoder().decode(Exercise.self, from: Data(json.utf8))
        #expect(ex.muscleGroup == nil)
    }

    @Test func decodesBilateralFlag() throws {
        let json = """
        {"id":"0025","n":"barbell bench press","bp":"chest","eq":"barbell","tg":"pectorals","bilateral":true}
        """
        let ex = try JSONDecoder().decode(Exercise.self, from: Data(json.utf8))
        #expect(ex.bilateral == true)
    }

    @Test func bilateralDefaultsToFalseWhenAbsent() throws {
        let json = #"{"id":"0025","n":"barbell bench press","bp":"chest","eq":"barbell","tg":"pectorals"}"#
        let ex = try JSONDecoder().decode(Exercise.self, from: Data(json.utf8))
        #expect(ex.bilateral == false)
    }

    @Test func bilateralRoundTripsThroughEncoding() throws {
        let ex = Exercise(id: "custom-1", name: "single arm row", bodyPart: "back", equipment: "dumbbell",
                          target: "lats", bilateral: false)
        let data = try JSONEncoder().encode(ex)
        let decoded = try JSONDecoder().decode(Exercise.self, from: data)
        #expect(decoded.bilateral == false)
        #expect(decoded == ex)
    }
}

@Suite struct ModelIdentityDecodingTests {
    /// Sync and MCP payloads must carry ids; a missing id must fail rather than mint a duplicate record.
    @Test func missingIdIsRejected() {
        let json = #"{"weightKg":20,"reps":10}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkoutSet.self, from: Data(json.utf8)) }
        let routine = #"{"name":"Push"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Routine.self, from: Data(routine.utf8)) }
    }
}
