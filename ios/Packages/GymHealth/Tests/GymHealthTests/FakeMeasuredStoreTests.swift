import Foundation
import GymCore
import Testing
@testable import GymHealth

/// Plan 40: the fake Health answers a GymRollins workout's measurements as HealthKitStore reads them (a phone copy's
/// time and calories never come back), and takes effort ratings only with access and a copy to relate them to.
@Suite struct FakeMeasuredStoreTests {
    private let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000f1")!
    private let start = ISO8601DateFormatter().date(from: "2026-09-19T18:00:00Z")!
    private var end: Date { start.addingTimeInterval(3_500) }

    private func copy(_ recordedBy: WorkoutMeasurements.Copy, effort: Effort? = nil) -> WorkoutMeasurements {
        WorkoutMeasurements(recordedBy: recordedBy, duration: 3_500, activeKcal: 412, totalKcal: 489,
                            heartRate: [HeartRateReading(date: start.addingTimeInterval(600), bpm: 128)],
                            postWorkout: [HeartRateReading(date: end.addingTimeInterval(118), bpm: 124)],
                            effort: effort)
    }

    @Test func aWorkoutAnswersWhatHealthHoldsAndAnyOtherNothing() async throws {
        let store = FakeHealthStore(measurements: [id: copy(.watch)])
        #expect(try await store.workoutMeasurements(externalId: id, start: start, end: end) == copy(.watch))
        #expect(try await store.workoutMeasurements(externalId: UUID(), start: start, end: end)
            == WorkoutMeasurements.none)
    }

    @Test func aPhoneCopyIsNeverReadAsMeasured() async throws {
        let store = FakeHealthStore()
        await store.setWorkoutMeasurements(copy(.phone), for: id)
        let read = try await store.workoutMeasurements(externalId: id, start: start, end: end)
        #expect(read.recordedBy == .phone)
        #expect(read.duration == nil && read.activeKcal == nil && read.totalKcal == nil)
        #expect(read.heartRate.map(\.bpm) == [128] && read.postWorkout.map(\.bpm) == [124], "heart rate still comes")
    }

    @Test func aRatingReplacesTheEffortAndClearingBringsBackHealthsOwn() async throws {
        let estimate = try #require(Effort(score: 5, estimated: true))
        let store = FakeHealthStore(measurements: [id: copy(.watch, effort: estimate)], effortAsked: true)
        try await store.rateEffort(externalId: id, score: 6)
        try await store.rateEffort(externalId: id, score: 8)
        #expect(await store.ratedEfforts == [id: 8])
        #expect(try await store.workoutMeasurements(externalId: id, start: start, end: end).effort
            == Effort(score: 8, estimated: false))
        try await store.clearEffort(externalId: id)
        #expect(await store.ratedEfforts.isEmpty)
        #expect(try await store.workoutMeasurements(externalId: id, start: start, end: end).effort == estimate)
    }

    @Test func aRatingNeedsAccessACopyAndAWorkingStore() async throws {
        let store = FakeHealthStore(measurements: [id: copy(.watch)])
        await #expect(throws: FakeHealthStore.Failure.self) { try await store.rateEffort(externalId: id, score: 6) }
        try await store.requestAuthorization()
        #expect(await store.effortTypesAsked())
        await #expect(throws: FakeHealthStore.Failure.self) {
            try await store.rateEffort(externalId: UUID(), score: 6)
        }
        await #expect(throws: FakeHealthStore.Failure.self) { try await store.rateEffort(externalId: id, score: 11) }
        await store.setFailEffortWrites(true)
        await #expect(throws: FakeHealthStore.Failure.self) { try await store.rateEffort(externalId: id, score: 6) }
        await #expect(throws: FakeHealthStore.Failure.self) { try await store.clearEffort(externalId: id) }
        #expect(await store.ratedEfforts.isEmpty)
    }

    /// `-fakeHealthEffortUnasked`: Health was turned on by build 4, whose request had no effort types; the next request
    /// (the Allow pill's) asks them.
    @Test func aRequestFromBeforeTheEffortTypesLeavesThemForTheNextOne() async throws {
        let store = FakeHealthStore(measurements: [id: copy(.watch)], firstRequestAsksEffort: false)
        try await store.requestAuthorization()
        #expect(await store.effortTypesAsked() == false)
        await #expect(throws: FakeHealthStore.Failure.self) { try await store.rateEffort(externalId: id, score: 6) }
        try await store.requestAuthorization()
        #expect(await store.effortTypesAsked())
        try await store.rateEffort(externalId: id, score: 6)
        #expect(await store.ratedEfforts == [id: 6])
    }

    @Test func aFailedSaveKeepsThePreviousRating() async throws {
        let store = FakeHealthStore(measurements: [id: copy(.watch)], effortAsked: true)
        try await store.rateEffort(externalId: id, score: 6)
        await store.setFailEffortWrites(true)
        await #expect(throws: FakeHealthStore.Failure.self) { try await store.rateEffort(externalId: id, score: 8) }
        #expect(await store.ratedEfforts == [id: 6])
        #expect(try await store.workoutMeasurements(externalId: id, start: start, end: end).effort
            == Effort(score: 6, estimated: false))
    }

    @Test func aFailedReadThrows() async throws {
        let store = FakeHealthStore(measurements: [id: copy(.watch)])
        await store.setFailReads(true)
        await #expect(throws: FakeHealthStore.Failure.self) {
            try await store.workoutMeasurements(externalId: id, start: start, end: end)
        }
    }
}
