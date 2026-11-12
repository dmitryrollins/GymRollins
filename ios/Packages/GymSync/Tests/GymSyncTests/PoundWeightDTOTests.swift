import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// Sets travel with `w_lb` and plan items with `weight_lb` (plan 38): sent only when there is a pound number, read when
/// a row has one, nil for rows without, and dropped when it disagrees with the kg.
@Suite struct PoundWeightDTOTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: SyncJSON.encoder.encode(value)) as? [String: Any])
    }

    private func set(_ json: String) throws -> WorkoutSet {
        let row = """
            {"id":"c0000000-0000-4000-8000-000000000001","position":0,"r":5,"done":true,"warmup":false,"multiplier":1,
             \(json)}
            """
        return try SyncJSON.decoder.decode(WorkoutSetDTO.self, from: Data(row.utf8)).domain
    }

    private func item(_ json: String) throws -> RoutineExercise {
        let row = """
            {"id":"c0000000-0000-4000-8000-000000000002","exercise_id":"bench","position":0,"sets":3,"reps":5,
             "mode":"reps",\(json)}
            """
        return try SyncJSON.decoder.decode(RoutineExerciseDTO.self, from: Data(row.utf8)).domain
    }

    // MARK: Sets

    @Test func aSetSendsItsPoundNumberAsWLbOnlyWhenItHasOne() throws {
        let pounds = WorkoutSet(weightKg: lb(45), weightLb: 45, reps: 5, done: true)
        #expect(try object(WorkoutSetDTO(pounds, position: 0))["w_lb"] as? Double == 45)
        #expect(try wire(WorkoutSetDTO(pounds, position: 0)).domain == pounds)
        let kg = WorkoutSet(weightKg: 20, reps: 5, done: true)
        #expect(try object(WorkoutSetDTO(kg, position: 0))["w_lb"] == nil)
    }

    @Test func aSetReadsWLbAndDropsADisagreeingOne() throws {
        #expect(try set(#""w_kg":20.41165665,"w_lb":45"#).weightLb == 45)
        #expect(try set(#""w_kg":20.41165665,"w_lb":null"#).weightLb == nil)
        #expect(try set(#""w_kg":20.41165665"#).weightLb == nil, "a row from before plan 38")
        let off = try set(#""w_kg":20.3,"w_lb":45"#)
        #expect(off.weightLb == nil && off.weightKg == 20.3)
    }

    @Test func aWorkoutCarriesItsSetsPoundNumbersBothWays() throws {
        let entry = WorkoutEntry(exerciseId: "bench", sets: [
            WorkoutSet(weightKg: lb(47.5), weightLb: 47.5, reps: 8, done: true),
            WorkoutSet(weightKg: 20, reps: 8, done: true),
        ])
        let workout = Workout(startedAt: t0, endedAt: t0, name: "Push", entries: [entry])
        let row = SyncRow(value: WorkoutSnapshot(workout: workout, records: [], volumeKg: 0), clientUpdatedAt: t0)
        #expect(try wire(WorkoutDTO(row)).toDomain().value.workout.entries[0].sets.map(\.weightLb) == [47.5, nil])
    }

    // MARK: Plan items

    @Test func aPlanItemSendsItsPoundNumberAsWeightLbOnlyWhenItHasOne() throws {
        let pounds = RoutineExercise(exerciseId: "bench", sets: 3, reps: 5, weightKg: lb(135), weightLb: 135)
        #expect(try object(RoutineExerciseDTO(pounds, position: 0))["weight_lb"] as? Double == 135)
        #expect(try wire(RoutineExerciseDTO(pounds, position: 0)).domain == pounds)
        let kg = RoutineExercise(exerciseId: "bench", sets: 3, reps: 5, weightKg: 60)
        #expect(try object(RoutineExerciseDTO(kg, position: 0))["weight_lb"] == nil)
        let routine = Routine(name: "Push", exercises: [pounds, kg])
        let row = SyncRow(value: RoutineSnapshot(routine: routine, position: 0), clientUpdatedAt: t0)
        #expect(try wire(RoutineDTO(row)).toDomain().value.routine.exercises.map(\.weightLb) == [135, nil])
    }

    @Test func aPlanItemReadsWeightLbAndDropsADisagreeingOne() throws {
        #expect(try item(#""weight_kg":61.23496995,"weight_lb":135"#).weightLb == 135)
        #expect(try item(#""weight_kg":61.23496995"#).weightLb == nil, "a row from before plan 38")
        #expect(try item(#""weight_kg":20.3,"weight_lb":45"#).weightLb == nil)
        #expect(try item(#""weight_lb":45"#).weightLb == nil, "no kg, no pounds")
    }
}
