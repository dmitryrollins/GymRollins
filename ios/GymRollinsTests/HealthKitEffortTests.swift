import Foundation
import GymCore
import GymHealth
import HealthKit
import Testing

/// Plan 40: HealthKit's two effort types read as an `Effort`: a rating, or the Apple Watch's estimate.
@Suite struct HealthKitEffortTests {
    private let date = ISO8601DateFormatter().date(from: "2026-09-19T18:58:20Z")!

    private func sample(_ type: HKQuantityTypeIdentifier, _ value: Double, unit: HKUnit = .appleEffortScore())
        -> HKQuantitySample {
        HKQuantitySample(type: HKQuantityType(type), quantity: HKQuantity(unit: unit, doubleValue: value), start: date,
                         end: date)
    }

    @Test func aRatingIsNotEstimatedAndTheWatchsEstimateIs() {
        #expect(HealthKitStore.effort(from: sample(.workoutEffortScore, 6)) == Effort(score: 6, estimated: false))
        #expect(HealthKitStore.effort(from: sample(.estimatedWorkoutEffortScore, 5.4))
            == Effort(score: 5, estimated: true))
    }

    @Test func anythingElseIsNoEffort() {
        // HealthKit takes 0–10 (anything else can't even be built); GymRollins' scale starts at 1.
        #expect(HealthKitStore.effort(from: sample(.workoutEffortScore, 0)) == nil)
        #expect(HealthKitStore.effort(from: sample(.estimatedWorkoutEffortScore, 0.4)) == nil, "rounds to 0")
        #expect(HealthKitStore.effort(from: sample(.workoutEffortScore, 10)) == Effort(score: 10, estimated: false))
        let bpm = HKUnit.count().unitDivided(by: .minute())
        #expect(HealthKitStore.effort(from: sample(.heartRate, 6, unit: bpm)) == nil)
    }

    // MARK: Writing a rating

    /// Once the new rating is saved and related, Health shows it: a failed removal of GymRollins' earlier rating is
    /// logged, not reported as "Couldn't save to Apple Health" (review fix A3).
    @Test func aFailedCleanupAfterTheRatingLandedIsStillASuccess() async throws {
        let steps = EffortSteps()
        try await HealthKitStore.writeRating(save: { await steps.add("save") }, relate: { await steps.add("relate") },
                                             deleteSaved: { await steps.add("deleteSaved") },
                                             deleteEarlier: {
                                                 await steps.add("deleteEarlier")
                                                 throw CocoaError(.fileWriteUnknown)
                                             })
        #expect(await steps.names == ["save", "relate", "deleteEarlier"])
    }

    @Test func aRatingThatCouldntBeRelatedIsDeletedAgainAndFails() async {
        let steps = EffortSteps()
        await #expect(throws: CocoaError.self) {
            try await HealthKitStore.writeRating(save: { await steps.add("save") },
                                                 relate: {
                                                     await steps.add("relate")
                                                     throw CocoaError(.fileWriteUnknown)
                                                 },
                                                 deleteSaved: { await steps.add("deleteSaved") },
                                                 deleteEarlier: { await steps.add("deleteEarlier") })
        }
        #expect(await steps.names == ["save", "relate", "deleteSaved"], "the earlier rating stays")
    }
}

/// The write steps `HealthKitStore.writeRating` ran, in order.
private actor EffortSteps {
    private(set) var names: [String] = []
    func add(_ name: String) { names.append(name) }
}
