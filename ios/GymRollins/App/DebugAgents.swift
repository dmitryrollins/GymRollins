#if DEBUG
import Foundation
import GymCore
import GymData
import GymSync

/// DEBUG/UI-test only, for Settings › AI agents and the workout screen without a server (plan 32).
/// - `-fakeAgents`: the Connected agents list is this in-memory one, made once per launch: Muse (agent.meta.ai,
///   connected a day ago, last used 2 h ago) above Claude (claude.ai, connected 6 days ago, never used). Disconnect
///   removes one for the rest of the launch. Disconnect all goes to the account as usual, so it leaves this list alone.
///   Nothing leaves the phone.
/// - `-seedAgentWorkout`: a past workout Muse added, stored as a pull stores it (clean, with `addedBy`).
@MainActor
final class DebugAgents {
    static let museId = "MuseFakeClientId"
    static let claudeId = "ClaudeFakeClientId"
    static let workoutId = UUID(uuidString: "AD0ED000-0000-4000-8000-000000000001")!
    private static let hour: TimeInterval = 3_600
    private static let day: TimeInterval = 86_400

    private var agents: [ConnectedAgent]

    init(now: Date) {
        agents = [
            ConnectedAgent(clientId: Self.museId, name: "Muse", host: "agent.meta.ai", knownHost: false,
                           connectedAt: now - Self.day, lastUsedAt: now - 2 * Self.hour),
            ConnectedAgent(clientId: Self.claudeId, name: "Claude", host: "claude.ai", knownHost: true,
                           connectedAt: now - 6 * Self.day, lastUsedAt: nil),
        ]
    }

    /// The calls Settings › AI agents makes. They hold this list, so it lives as long as the launch's environment.
    var calls: AgentCalls {
        AgentCalls(list: { [self] in agents }, disconnect: { [self] clientId in try remove(clientId) })
    }

    private func remove(_ clientId: String) throws {
        guard agents.contains(where: { $0.clientId == clientId }) else { throw AgentError.unknownAgent }
        agents = agents.filter { $0.clientId != clientId }
    }

    /// `-seedAgentWorkout`: "Upper", four days before `now` (Tuesday 22 Sep under the UI tests' fixed now), bench press
    /// 8, 8 and 7 at 63.5 kg, as Muse's `log_workout` lands after a pull.
    static func seedWorkout(into store: SyncStore, now: Date) throws {
        let start = now - 4 * day
        let sets = [8, 8, 7].map { WorkoutSet(weightKg: 63.5, reps: $0, done: true, completedAt: start) }
        let workout = Workout(id: workoutId, startedAt: start, endedAt: start + 63 * 60, name: "Upper",
                              entries: [WorkoutEntry(exerciseId: "0025", sets: sets)], source: .import)
        let snapshot = WorkoutSnapshot(workout: workout, records: [], volumeKg: WorkoutMetrics.volumeKg(workout),
                                       addedBy: "Muse")
        try store.applyRemote(workouts: [SyncRow(value: snapshot, clientUpdatedAt: now, serverUpdatedAt: now)])
    }
}
#endif
