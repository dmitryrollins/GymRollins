import GymCore
import Testing
@testable import GymRollins

@Suite struct WorkoutTextTests {
    private func lb(_ v: Double) -> Double { UnitConverter.toKg(v, from: .lb) }
    private func entry(_ sets: [(Double, Int)], warmup: Bool = false) -> WorkoutEntry {
        WorkoutEntry(exerciseId: "x", sets: sets.map { WorkoutSet(weightKg: lb($0.0), reps: $0.1, done: true) })
    }

    @Test func equalSets() { #expect(WorkoutText.setsSummary(entry([(130, 10), (130, 10), (130, 10)]), unit: .lb) == "3 × 10 @ 130 lb") }
    @Test func varyingReps() { #expect(WorkoutText.setsSummary(entry([(44, 10), (44, 10), (44, 12)]), unit: .lb) == "10, 10, 12 @ 44 lb") }
    @Test func varyingWeights() { #expect(WorkoutText.setsSummary(entry([(25, 12), (27.5, 12)]), unit: .lb) == "12, 12 @ 25–27.5 lb") }
    @Test func bodyweight() { #expect(WorkoutText.setsSummary(entry([(0, 10), (0, 10), (0, 8)]), unit: .lb) == "10, 10, 8") }
    @Test func warmupsExcluded() {
        let e = WorkoutEntry(exerciseId: "x", sets: [WorkoutSet(weightKg: lb(45), reps: 10, done: true, warmup: true),
                                                      WorkoutSet(weightKg: lb(130), reps: 8, done: true)])
        #expect(WorkoutText.setsSummary(e, unit: .lb) == "1 × 8 @ 130 lb")
    }

    private func timedEntry(_ secs: [Int]) -> WorkoutEntry {
        WorkoutEntry(exerciseId: "plank", sets: secs.map { WorkoutSet(weightKg: 0, reps: 1, sec: $0, done: true) })
    }

    @Test func equalTimedSets() {
        #expect(WorkoutText.setsSummary(timedEntry([30, 30, 30]), unit: .lb, mode: .time) == "3 × 0:30")
    }

    @Test func varyingTimedSets() {
        #expect(WorkoutText.setsSummary(timedEntry([30, 45]), unit: .lb, mode: .time) == "0:30, 0:45")
    }

    private func cardioEntry(minutes: Double, distanceM: Double?) -> WorkoutEntry {
        WorkoutEntry(exerciseId: "run", sets: [WorkoutSet(weightKg: 0, reps: 1, minutes: minutes, distanceM: distanceM, done: true)])
    }

    @Test func cardioWithDistanceInKm() {
        #expect(WorkoutText.setsSummary(cardioEntry(minutes: 20, distanceM: 3_200), unit: .kg, mode: .cardio) == "20 min \u{00B7} 3.2 km")
    }

    @Test func cardioWithDistanceInMiles() {
        let entry = cardioEntry(minutes: 20, distanceM: SetFieldFormat.metersPerMile * 2)
        #expect(WorkoutText.setsSummary(entry, unit: .lb, mode: .cardio) == "20 min \u{00B7} 2 mi")
    }

    @Test func cardioWithoutDistance() {
        #expect(WorkoutText.setsSummary(cardioEntry(minutes: 20, distanceM: nil), unit: .kg, mode: .cardio) == "20 min")
    }
}
