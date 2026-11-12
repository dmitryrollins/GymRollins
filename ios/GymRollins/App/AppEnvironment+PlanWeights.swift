import Foundation
import GymCore

extension AppEnvironment {
    /// Plan 38's one-time cleanup of plan weights (`PlanWeightsLbCleanup`), run at launch before any screen reads the
    /// plan, and again after pulled changes are applied until it has run (a reinstall or a new sign-in launches with
    /// no plan, and the pull brings the server's). Changed workouts are saved dirty, screens reload and a sync is
    /// scheduled. It can't loop: a sync is scheduled only when something changed, and once the flag is set a run does
    /// nothing. A failure to read the plan is logged and leaves the flag unset, so the next launch or pull tries again.
    func cleanUpPlanWeightsOnce() {
        do {
            let changed = try PlanWeightsLbCleanup.runOnce(routines: routines, profile: profile, library: library,
                                                           defaults: defaults)
            guard changed > 0 else { return }
            Self.log.info("Plan weights got their pound numbers in \(changed) workouts")
            planChanged()
        } catch {
            Self.log.error("Plan weight cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
