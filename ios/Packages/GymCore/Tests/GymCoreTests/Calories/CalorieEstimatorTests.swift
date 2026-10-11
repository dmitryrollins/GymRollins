import Foundation
import Testing
@testable import GymCore

@Suite struct CalorieEstimatorTests {
    typealias F = CalorieFixture

    // MARK: Formula

    @Test func strengthWorkoutUsesMetTimesKgTimesHours() throws {
        // 60 min, 9 working sets, no RPE: 60/9 = 6.7 min per set → light → 02054 (3.5 MET).
        let w = F.workout(minutes: 60, [("bench", F.sets(5)), ("curl", F.sets(4))])
        let e = try #require(F.estimate(w))
        #expect(e.effort == .light)
        #expect(e.kcal == 280) // 3.5 × 80 × 1
        #expect(e.parts.map(\.code) == ["02054"])
        #expect(e.bodyWeightKg == 80)
        #expect(!e.usedDefaultBodyWeight)
        #expect(e.healthActivity == .strength)
        #expect(e.activeSeconds == 3_600)
    }

    /// Apple Health's active energy excludes resting energy (1 MET): (MET − 1) × kg × h.
    @Test func activeKcalExcludesTheRestingMET() throws {
        let w = F.workout(minutes: 60, [("bench", F.sets(20, rpe: 7))])
        let e = try #require(F.estimate(w))
        #expect(e.kcal == 280)
        #expect(e.activeKcal == 200) // (3.5 − 1) × 80 × 1
    }

    @Test func pausedTimeIsExcluded() throws {
        let w = F.workout(minutes: 60, paused: 1_800, [("bench", F.sets(20, rpe: 7))])
        let e = try #require(F.estimate(w))
        #expect(e.activeSeconds == 3_600)
        #expect(e.kcal == 280)
    }

    @Test func missingBodyWeightFallsBackToDefaultAndSaysSo() throws {
        let w = F.workout(minutes: 60, [("bench", F.sets(20, rpe: 7))])
        let e = try #require(F.estimate(w, kg: nil))
        #expect(e.usedDefaultBodyWeight)
        #expect(e.bodyWeightKg == CalorieEstimator.defaultBodyWeightKg)
        #expect(e.kcal == 245) // 3.5 × 70
    }

    @Test func implausibleBodyWeightIsTreatedAsMissing() throws {
        let w = F.workout(minutes: 60, [("bench", F.sets(20, rpe: 7))])
        #expect(try #require(F.estimate(w, kg: 0)).usedDefaultBodyWeight)
        #expect(try #require(F.estimate(w, kg: .nan)).usedDefaultBodyWeight)
    }

    @Test func veryShortOrUnfinishedWorkoutsHaveNoEstimate() {
        #expect(F.estimate(F.workout(minutes: 0.9, [("bench", F.sets(1))])) == nil)
        #expect(F.estimate(F.workout(minutes: 60, ended: false, [("bench", F.sets(3))])) == nil)
    }

    @Test func workoutWithoutWorkingSetsHasNoEstimate() {
        let w = F.workout(minutes: 30, [("bench", F.sets(3, warmup: true)), ("curl", F.sets(3, done: false))])
        #expect(F.estimate(w) == nil)
    }

    @Test func longWorkoutsAreCappedAtFourHours() throws {
        let w = F.workout(minutes: 600, [("bench", F.sets(20, rpe: 7))])
        let e = try #require(F.estimate(w))
        #expect(e.wasCapped)
        #expect(e.activeSeconds == 4 * 3_600)
        #expect(e.kcal == 1_120) // 3.5 × 80 × 4
    }

    @Test func warmupsDoNotCountButStillShareTime() throws {
        // Only the working sets decide the split; the whole active time is still spent.
        let w = F.workout(minutes: 60, [("bench", F.sets(2, warmup: true) + F.sets(3, rpe: 7))])
        #expect(try #require(F.estimate(w)).kcal == 280)
    }

    // MARK: Effort

    @Test func effortFromRPEAndRIR() throws {
        let vigorous = F.workout(minutes: 60, [("bench", F.sets(10, rir: 1))]) // RPE 9
        let moderate = F.workout(minutes: 60, [("bench", F.sets(10, rpe: 7))])
        let light = F.workout(minutes: 60, [("bench", F.sets(10, rpe: 5))])
        #expect(try #require(F.estimate(vigorous)).effort == .vigorous)
        #expect(try #require(F.estimate(vigorous)).kcal == 480) // 02050: 6.0 × 80
        #expect(try #require(F.estimate(moderate)).effort == .moderate)
        #expect(try #require(F.estimate(light)).effort == .light)
    }

    @Test func effortBoundariesAreInclusive() {
        #expect(EffortRule.fromRPE(8.5) == .vigorous)
        #expect(EffortRule.fromRPE(8.49) == .moderate)
        #expect(EffortRule.fromRPE(6) == .moderate)
        #expect(EffortRule.fromRPE(5.99) == .light)
        #expect(EffortRule.fromDensity(minutesPerSet: 1.5) == .vigorous)
        #expect(EffortRule.fromDensity(minutesPerSet: 4) == .moderate)
        #expect(EffortRule.fromDensity(minutesPerSet: 4.01) == .light)
    }

    @Test func effortFromRestDensityWhenNothingLogged() throws {
        let dense = F.workout(minutes: 30, [("bench", F.sets(24))])   // 1.25 min/set
        let normal = F.workout(minutes: 60, [("bench", F.sets(20))])  // 3 min/set
        #expect(try #require(F.estimate(dense)).effort == .vigorous)
        #expect(try #require(F.estimate(normal)).effort == .moderate)
    }

    @Test func squatAndDeadliftUseTheirOwnCodeAtModerateEffort() throws {
        let w = F.workout(minutes: 60, [("squat", F.sets(10, rpe: 7)), ("bench", F.sets(10, rpe: 7))])
        let e = try #require(F.estimate(w))
        #expect(Set(e.parts.map(\.code)) == ["02052", "02054"])
        #expect(e.kcal == 340) // 30 min × 5.0 + 30 min × 3.5 → (2.5 + 1.75) × 80
    }

    // MARK: Activities

    @Test func calisthenicsUseTheCalisthenicsCodes() throws {
        let w = F.workout(minutes: 60, [("pushup", F.sets(10, kg: 0, rpe: 7))])
        let e = try #require(F.estimate(w))
        #expect(e.parts.map(\.code) == ["02022"])
        #expect(e.kcal == 304) // 3.8 × 80
    }

    @Test func pairedSupersetsUseReciprocalSupersetCode() throws {
        let w = F.workout(minutes: 60, [("bench", F.sets(5, rpe: 7)), ("fly", F.sets(5, rpe: 7))], groups: ["A", "A"])
        let e = try #require(F.estimate(w))
        #expect(e.parts.map(\.code) == ["02055"])
        #expect(e.kcal == 464) // 5.8 × 80
    }

    @Test func threeExerciseGroupsAreCircuits() throws {
        let w = F.workout(minutes: 60, [("bench", F.sets(3, rpe: 9)), ("fly", F.sets(3, rpe: 9)),
                                        ("pushup", F.sets(3, rpe: 9))], groups: ["A", "A", "A"])
        let e = try #require(F.estimate(w))
        #expect(e.parts.map(\.code) == ["02040"])
        #expect(e.kcal == 600) // 7.5 × 80
    }

    @Test func loggedCardioTimeIsUsedAndTheRestGoesToStrength() throws {
        // 60 min: 20 min run logged, 40 min for 10 bench sets at RPE 7 (moderate → 02054).
        let w = F.workout(minutes: 60, [("run", F.sets(1, kg: 0, reps: 0, minutes: 20)),
                                        ("bench", F.sets(10, rpe: 7))])
        let e = try #require(F.estimate(w))
        let run = try #require(e.parts.first { $0.code == "12150" })
        let bench = try #require(e.parts.first { $0.code == "02054" })
        #expect(abs(run.minutes - 20) < 0.001)
        #expect(abs(bench.minutes - 40) < 0.001)
        #expect(e.kcal == 400) // 8 × 80 / 3 + 3.5 × 80 × 2 / 3 = 213.3 + 186.7
        #expect(e.healthActivity == .strength)
    }

    @Test func cardioTimeLongerThanTheWorkoutIsScaledDown() throws {
        let w = F.workout(minutes: 30, [("run", F.sets(1, kg: 0, reps: 0, minutes: 45))])
        let e = try #require(F.estimate(w))
        #expect(abs(e.parts[0].minutes - 30) < 0.001)
        #expect(e.kcal == 320) // 8 × 80 × 0.5
    }

    @Test func cardioOnlyLeftoverTimeIsNotCounted() throws {
        let w = F.workout(minutes: 40, [("run", F.sets(1, kg: 0, reps: 0, minutes: 30))])
        let e = try #require(F.estimate(w))
        #expect(e.kcal == 320)
        #expect(e.healthActivity == .running)
    }

    @Test func secondsCountAsCardioTime() throws {
        let w = F.workout(minutes: 30, [("bike", F.sets(1, kg: 0, reps: 0, sec: 1_800))])
        let e = try #require(F.estimate(w))
        #expect(e.parts.map(\.code) == ["01200"])
        #expect(e.kcal == 272) // 6.8 × 80 × 0.5
        #expect(e.healthActivity == .cycling)
    }

    @Test func untimedCardioSharesTimeBySets() throws {
        let w = F.workout(minutes: 20, [("burpee", F.sets(4, kg: 0, reps: 15))])
        let e = try #require(F.estimate(w))
        #expect(e.parts.map(\.code) == ["02210"])
        #expect(e.healthActivity == .hiit)
    }

    @Test func dominantCardioKindWinsForCardioOnlySessions() throws {
        let w = F.workout(minutes: 60, [("run", F.sets(1, kg: 0, reps: 0, minutes: 10)),
                                        ("bike", F.sets(1, kg: 0, reps: 0, minutes: 40))])
        #expect(try #require(F.estimate(w)).healthActivity == .cycling)
    }

    @Test func unknownExercisesFallBackOnTheirSets() throws {
        let w = F.workout(minutes: 60, [("mystery", F.sets(10, kg: 40, rpe: 7))])
        #expect(try #require(F.estimate(w)).parts.map(\.code) == ["02054"])
        let body = F.workout(minutes: 60, [("mystery", F.sets(10, kg: 0, rpe: 7))])
        #expect(try #require(F.estimate(body)).parts.map(\.code) == ["02022"])
        let cardio = F.workout(minutes: 30, [("mystery", F.sets(1, kg: 0, reps: 0, minutes: 30))])
        #expect(try #require(F.estimate(cardio)).parts.map(\.code) == ["02060"])
    }

    @Test func missingCodeInTableGivesNoEstimate() {
        let empty = METTable(source: CalorieFixture.table.source, activities: [])
        let w = F.workout(minutes: 60, [("bench", F.sets(5))])
        #expect(CalorieEstimator.estimate(workout: w, exercise: F.lookup, bodyWeightKg: 80, table: empty) == nil)
    }

    // MARK: Table

    @Test func tableDecodesFromJSON() throws {
        let json = """
        {"source":{"title":"t","citation":"c","url":"u","retrieved":"r","terms":["x"]},
         "activities":[{"code":"02050","met":6.0,"description":"Resistance","heading":"Conditioning Exercise"}]}
        """
        let table = try METTable.decode(Data(json.utf8))
        #expect(table.met(for: "02050") == 6.0)
        #expect(table.met(for: "99999") == nil)
    }

    @Test func everyActivityCodeIsDefined() {
        for activity in CalorieActivity.allCases {
            for effort in EffortLevel.allCases {
                #expect(F.table.met(for: activity.code(effort: effort)) != nil, "\(activity) \(effort)")
            }
        }
        #expect(Set(CalorieActivity.allCodes).count == F.table.activities.count)
    }
}
