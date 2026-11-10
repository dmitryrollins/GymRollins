import Foundation
import GymData
import Observation

/// Whether the signed-in user is a moderator, asked once per sign-in. The Moderation row is a convenience: the server
/// refuses a non-admin whatever the phone shows.
@MainActor
@Observable
final class GymAdminStatus {
    private(set) var isAdmin = false
    @ObservationIgnored private var checkedUser: UUID?
    /// Counts sessions ended, so an answer that comes back after a sign-out or an account change is thrown away.
    @ObservationIgnored private var generation = 0

    /// Signed out (`userId` nil) forgets the answer and asks nothing. A failed or offline check hides the row and
    /// leaves the next call to ask again.
    func refresh(userId: UUID?, ask: () async throws -> Bool) async {
        guard let userId else { reset(); return }
        if checkedUser == userId { return }
        if checkedUser != nil { reset() }
        let started = generation
        do {
            let answer = try await ask()
            guard started == generation else { return }
            isAdmin = answer
            checkedUser = userId
        } catch {
            guard started == generation else { return }
            isAdmin = false
            AppEnvironment.log.error("Admin check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reset() {
        generation += 1
        isAdmin = false
        checkedUser = nil
    }
}
