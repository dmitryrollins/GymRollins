import Foundation

/// What signing out would delete from this iPhone after a last sync attempt.
struct SignOutReport: Equatable {
    /// Local changes still not on the server.
    let unsynced: Int
    /// Changes the server refused (listed in Account).
    let failed: Int
    /// A workout is in progress (it never syncs before it's finished).
    let workoutInProgress: Bool

    /// Nothing would be lost: the plain "remove this iPhone's copy" confirmation is enough.
    var isSafe: Bool { unsynced == 0 && failed == 0 && !workoutInProgress }

    /// E.g. "2 changes not uploaded, 1 workout in progress will be deleted from this iPhone."
    var warning: String {
        var parts: [String] = []
        if unsynced > 0 { parts.append("\(unsynced) \(unsynced == 1 ? "change" : "changes") not uploaded") }
        if failed > 0 { parts.append("\(failed) \(failed == 1 ? "change" : "changes") the server refused") }
        if workoutInProgress { parts.append("1 workout in progress") }
        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: ", ") + " will be deleted from this iPhone."
    }
}

// Sign-out safety: a last sync, then an explicit list of what would be lost.
extension AppEnvironment {
    func prepareSignOut() async -> SignOutReport {
        let (unsynced, failed) = await sync.finalSync()
        let active = session != nil || ((try? workouts.active()) ?? nil) != nil
        return SignOutReport(unsynced: unsynced, failed: failed, workoutInProgress: active)
    }
}
