import Foundation
import GymCore
import GymData

/// What an exercise row says Start will do: "3 × 10 · 53 lb (24 kg)". Today's rows and Build workout's result both use
/// it, so a row never promises a weight or rep target the workout won't start with.
struct PlannedTarget: Equatable {
    let subtitle: String
    let suggestedKg: Double?
    /// "+5 lb" over the last session, when the weight goes up.
    let badge: String?

    static func make(item: RoutineExercise, policy: ProgressionPolicy, profile: Profile, exercise: Exercise?,
                     history: [SessionResult], loads: ListingLoads?) -> PlannedTarget {
        let suggest = { (loads: ListingLoads?) in
            SessionPlanner.suggestion(for: item, policy: policy, profile: profile, exercise: exercise, history: history,
                                      loads: loads)
        }
        let suggestion = suggest(loads)
        // Past the gym's heaviest weight the target is the raised number the workout will start with.
        let raisedReps = loads != nil && suggestion.reps > suggest(nil).reps
        let reps = raisedReps ? "\(suggestion.reps)"
            : item.repsMin.map { $0 < item.reps ? "\($0)\u{2013}\(item.reps)" : "\(item.reps)" } ?? "\(item.reps)"
        let load = suggestion.weightKg > 0
            ? " \u{00B7} " + WeightFormatter.format(kg: suggestion.weightKg, unit: profile.unit)
            : ""
        let delta = history.first.map { suggestion.weightKg - $0.weightKg } ?? 0
        // At a gym a weight within the bell's own rounding (44 lb vs a 20 kg bell) hasn't risen; with none, any
        // real rise, even a 0.2 kg micro-plate, shows.
        let badge = delta > (loads != nil ? AvailableLoads.toleranceKg : 0.01)
            ? "+\(WeightFormatter.format(kg: delta, unit: profile.unit, includeSecondary: false))"
            : nil
        return PlannedTarget(subtitle: "\(item.sets) \u{00D7} \(reps)\(load)", suggestedKg: suggestion.weightKg > 0 ? suggestion.weightKg : nil,
                             badge: badge)
    }
}
