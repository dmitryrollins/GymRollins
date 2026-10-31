import Foundation

/// What signing out would delete from this iPhone after a last sync attempt.
struct SignOutReport: Equatable {
    /// Local changes still not on the server.
    let unsynced: Int
    /// Changes the server refused (listed in Account).
    let failed: Int
    /// A workout is in progress (it never syncs before it's finished).
    let workoutInProgress: Bool
    /// Reports and blocks made offline that still haven't reached the server.
    let unsentReports: Int

    init(unsynced: Int, failed: Int, workoutInProgress: Bool, unsentReports: Int = 0) {
        self.unsynced = unsynced
        self.failed = failed
        self.workoutInProgress = workoutInProgress
        self.unsentReports = unsentReports
    }

    /// Nothing would be lost: the plain "remove this iPhone's copy" confirmation is enough.
    var isSafe: Bool { unsynced == 0 && failed == 0 && !workoutInProgress && unsentReports == 0 }

    /// E.g. "2 changes not uploaded, 1 workout in progress will be deleted from this iPhone. 1 report hasn't been sent
    /// and will be lost."
    var warning: String {
        var parts: [String] = []
        if unsynced > 0 { parts.append("\(unsynced) \(unsynced == 1 ? "change" : "changes") not uploaded") }
        if failed > 0 { parts.append("\(failed) \(failed == 1 ? "change" : "changes") the server refused") }
        if workoutInProgress { parts.append("1 workout in progress") }
        var sentences: [String] = []
        if !parts.isEmpty { sentences.append(parts.joined(separator: ", ") + " will be deleted from this iPhone.") }
        if unsentReports == 1 { sentences.append("1 report hasn't been sent and will be lost.") }
        if unsentReports > 1 { sentences.append("\(unsentReports) reports haven't been sent and will be lost.") }
        return sentences.joined(separator: " ")
    }
}

// Sign-out safety: a last sync, then an explicit list of what would be lost.
extension AppEnvironment {
    func prepareSignOut() async -> SignOutReport {
        let (unsynced, failed) = await sync.finalSync()
        let unsentReports = await sendQueuedReports()
        let active = session != nil || ((try? workouts.active()) ?? nil) != nil
        return SignOutReport(unsynced: unsynced, failed: failed, workoutInProgress: active,
                             unsentReports: unsentReports)
    }
}
