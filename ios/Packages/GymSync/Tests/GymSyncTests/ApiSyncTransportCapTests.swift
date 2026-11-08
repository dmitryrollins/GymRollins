import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// The storage caps (server/src/sync/caps.ts) as `ApiSyncTransport` meets them: 422 with the cap's code and the
/// server's words, which the engine records beside the row it keeps.
@Suite struct ApiSyncTransportCapTests {
    private let t0 = SyncDate.parse("2026-11-08T08:00:00.123456Z")!
    /// Every code a sync push can meet at a cap; Claude's two proposal codes never reach the app.
    private let codes = ["too_many_workouts", "too_many_body_weights", "too_many_routines",
                         "too_many_custom_exercises", "too_many_exercise_prefs", "too_many_gyms_total",
                         "too_many_listings_total", "too_many_logged_exercises", "too_many_logged_sets",
                         "too_many_workout_exercises", "too_many_exercise_sets"]
    private let words = "You've reached the limit of 20,000 weigh-ins on one account, deleted ones included. "
        + "This one stays on this iPhone."

    private func refusing(_ code: String) -> StubServer {
        StubServer { _ in .json(422, #"{"error": {"code": "\#(code)", "message": "\#(words)"}}"#) }
    }

    @Test func aCapRefusesABatchWithTheServersWords() async throws {
        let row = BodyweightDTO(SyncRow(value: BodyweightEntry(date: t0, weightKg: 81), clientUpdatedAt: t0))
        for code in codes {
            let server = refusing(code) // held for the request: its deinit unregisters the host
            await #expect(throws: SyncRecordRejected(code: code, message: words)) {
                _ = try await ApiSyncTransport(api: server.client()).push(bodyweight: [row])
            }
        }
    }

    @Test func aCapRefusesAWorkoutWithTheServersWords() async throws {
        let workout = Workout(startedAt: t0, endedAt: t0 + 600, name: "Push", entries: [
            WorkoutEntry(exerciseId: "bench", sets: [WorkoutSet(weightKg: 60, reps: 8, done: true)]),
        ])
        let dto = WorkoutDTO(SyncRow(value: WorkoutSnapshot(workout: workout, records: [], volumeKg: 480),
                                     clientUpdatedAt: t0 + 600))
        for code in codes {
            let server = refusing(code)
            await #expect(throws: SyncRecordRejected(code: code, message: words)) {
                _ = try await ApiSyncTransport(api: server.client()).push(workout: dto)
            }
        }
    }
}
