import Foundation

public extension SharedWorkout {
    /// What one exercise on the sender's phone contributes, before limits and numbering.
    struct Source: Equatable, Sendable {
        public let exerciseId: String
        public let sets: Int
        public let target: Target
        public let group: String?

        public init(exerciseId: String, sets: Int, target: Target, group: String?) {
            self.exerciseId = exerciseId
            self.sets = sets
            self.target = target
            self.group = group
        }

        public init(item: RoutineExercise) {
            let seconds = item.mode == .reps ? nil : item.sec
            self.init(exerciseId: item.exerciseId, sets: item.sets,
                      target: seconds.map(Target.seconds) ?? .reps(min: item.repsMin, max: item.reps),
                      group: item.supersetGroup)
        }

        /// Edited or running sets: the number of working sets and the first one's target. Nil with no working sets.
        public init?(exerciseId: String, group: String?, sets: [WorkoutSet]) {
            let working = sets.filter { !$0.warmup }
            // The plan's number, not what was just logged: the first set still to do, or the first when all are done.
            guard let first = working.first(where: { !$0.done }) ?? working.first else { return nil }
            let target: Target
            if let sec = first.sec {
                target = .seconds(sec)
            } else if let minutes = first.minutes, minutes.isFinite {
                target = .seconds(Int(min(max(minutes, 0), 60) * 60))
            } else {
                target = .reps(min: nil, max: first.reps)
            }
            self.init(exerciseId: exerciseId, sets: working.count, target: target, group: group)
        }

        public init?(entry: WorkoutEntry) {
            self.init(exerciseId: entry.exerciseId, group: entry.supersetGroup, sets: entry.sets)
        }
    }

    /// What can go in a link, and what can't.
    struct Draft: Equatable, Sendable {
        /// Nil when nothing can go.
        public let workout: SharedWorkout?
        /// Exercises that aren't in the shared library, such as custom ones.
        public let leftOutIds: [String]
        /// Exercises past `DomainLimits.routineExercisesMax`.
        public let cutOffCount: Int
    }

    /// Applies the limits (values are clamped, so a sender can always share) and numbers the supersets.
    static func make(from sources: [Source]) -> Draft {
        // A running workout can hold an exercise twice; a link names each once, so the first one goes.
        var seen = Set<String>()
        let shareable = sources.filter { isShareableId($0.exerciseId) && seen.insert($0.exerciseId).inserted }
        let kept = Array(shareable.prefix(DomainLimits.routineExercisesMax))
        let numbers = kept.compactMap(\.group).reduce(into: [String: Int]()) { numbers, group in
            if numbers[group] == nil { numbers[group] = numbers.count + 1 }
        }
        let items = kept.map { source in
            Item(exerciseId: source.exerciseId, sets: clamp(source.sets, to: PlanChangeLimits.sets),
                 target: limited(source.target), superset: source.group.flatMap { numbers[$0] })
        }
        return Draft(workout: items.isEmpty ? nil : SharedWorkout(items: items),
                     leftOutIds: sources.map(\.exerciseId).filter { !isShareableId($0) },
                     cutOffCount: shareable.count - kept.count)
    }

    private static func limited(_ target: Target) -> Target {
        switch target {
        case let .reps(low, high):
            let top = clamp(high, to: PlanChangeLimits.reps)
            let bottom = low.map { clamp($0, to: PlanChangeLimits.reps.lowerBound...top) }
            return .reps(min: bottom == top ? nil : bottom, max: top)
        case let .seconds(seconds):
            return .seconds(clamp(seconds, to: PlanChangeLimits.sec))
        }
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
