import Foundation
import GymCore
import Testing
@testable import GymRollins

@Suite struct WorkoutAccessibilityTextTests {
    private let lb140 = 140 * UnitConverter.kgPerLb

    @Test func workingSetDoneInPounds() {
        let set = WorkoutSet(weightKg: lb140, reps: 8, done: true)
        #expect(SetAccessibilityText.rowLabel(set: set, ordinal: .working(1), mode: .reps, unit: .lb, isActive: false)
            == "Set 1, 8 reps, 140 pounds, done")
    }

    @Test func warmupAndStatusesAndKilograms() {
        let warmup = WorkoutSet(weightKg: 20, reps: 5, warmup: true)
        #expect(SetAccessibilityText.rowLabel(set: warmup, ordinal: .warmup(2), mode: .reps, unit: .kg, isActive: false)
            == "Warm-up set 2, 5 reps, 20 kilograms, not done")
        let single = WorkoutSet(weightKg: 62.5, reps: 1)
        #expect(SetAccessibilityText.rowLabel(set: single, ordinal: .working(3), mode: .reps, unit: .kg, isActive: true)
            == "Set 3, 1 rep, 62.5 kilograms, current set")
    }

    @Test func plannedSetsHaveNoStatus() {
        let set = WorkoutSet(weightKg: lb140, reps: 8)
        #expect(SetAccessibilityText.rowLabel(set: set, ordinal: .working(2), mode: .reps, unit: .lb, isActive: true,
                                              isPlanned: true) == "Set 2, 8 reps, 140 pounds")
    }

    @Test func bodyweightTimeAndCardio() {
        let pushup = WorkoutSet(weightKg: 0, reps: 12, done: true)
        #expect(SetAccessibilityText.rowLabel(set: pushup, ordinal: .working(1), mode: .reps, unit: .lb, isActive: false)
            == "Set 1, 12 reps, bodyweight, done")
        let plank = WorkoutSet(weightKg: 0, reps: 1, sec: 45, done: true)
        #expect(SetAccessibilityText.rowLabel(set: plank, ordinal: .working(2), mode: .time, unit: .lb, isActive: false)
            == "Set 2, 45 seconds, bodyweight, done")
        let run = WorkoutSet(weightKg: 0, reps: 0, minutes: 20, distanceM: 1_609.344 * 2, done: true)
        #expect(SetAccessibilityText.rowLabel(set: run, ordinal: .working(1), mode: .cardio, unit: .lb, isActive: false)
            == "Set 1, 20 minutes, 2 miles, done")
        let bike = WorkoutSet(weightKg: 0, reps: 0, minutes: 1, done: false)
        #expect(SetAccessibilityText.rowLabel(set: bike, ordinal: .working(1), mode: .cardio, unit: .kg, isActive: false)
            == "Set 1, 1 minute, not done")
    }

    @Test func ordinals() {
        let sets = [WorkoutSet(weightKg: 20, reps: 5, warmup: true), WorkoutSet(weightKg: 40, reps: 5, warmup: true),
                    WorkoutSet(weightKg: 60, reps: 8), WorkoutSet(weightKg: 60, reps: 8)]
        #expect(SetOrdinal.ordinals(for: sets) == [.warmup(1), .warmup(2), .working(1), .working(2)])
        #expect(SetOrdinal.working(2).workingPosition == 2)
        #expect(SetOrdinal.warmup(1).workingPosition == nil)
    }

    @Test func restValueIsSpokenDuration() {
        #expect(RestAccessibilityText.value(remaining: 105) == "1 minute 45 seconds remaining")
        #expect(RestAccessibilityText.value(remaining: 120) == "2 minutes remaining")
        #expect(RestAccessibilityText.value(remaining: 0.4) == "1 second remaining")
        #expect(RestAccessibilityText.value(remaining: 0) == "0 seconds remaining")
    }

    /// Announces only when crossing the 10-second mark (sparingly: not every tick).
    @Test func restAnnouncementOnlyAtTenSeconds() {
        #expect(RestAccessibilityText.announcement(from: 11, to: 10) == "10 seconds left")
        #expect(RestAccessibilityText.announcement(from: 12, to: 9) == "10 seconds left")
        #expect(RestAccessibilityText.announcement(from: 10, to: 9) == nil)
        #expect(RestAccessibilityText.announcement(from: 60, to: 59) == nil)
        #expect(RestAccessibilityText.announcement(from: 5, to: 20) == nil)
        #expect(RestAccessibilityText.restOver == "Rest over")
    }
}
