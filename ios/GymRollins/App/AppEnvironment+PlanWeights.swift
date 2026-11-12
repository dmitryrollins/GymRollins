import Foundation
import GymCore

extension AppEnvironment {
    /// Plan 38's one-time cleanup of plan weights (`PlanWeightsLbCleanup`), run at launch before any screen reads the
    /// plan. Changed workouts are saved dirty and a sync is scheduled. A failure is logged and leaves the flag unset, so
    /// the next launch tries again.
    func cleanUpPlanWeightsOnce() {
        do {
            let changed = try PlanWeightsLbCleanup.runOnce(routines: routines, profile: profile, library: library,
                                                           defaults: defaults)
            guard changed > 0 else { return }
            Self.log.info("Plan weights got their pound numbers in \(changed) workouts")
            sync.localDataChanged()
        } catch {
            Self.log.error("Plan weight cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
