import Foundation

/// One day's workout as it travels between two phones (docs/specs/2026-11-01-shared-workout-design.md): library exercise
/// ids and numbers only. No weights, warm-ups, rest, names or other text, so each phone plans it from its own history and a
/// link can't put a stranger's words in the app.
public struct SharedWorkout: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// `min` is nil for a single rep count.
        case reps(min: Int?, max: Int)
        case seconds(Int)
    }

    public struct Item: Equatable, Sendable {
        public let exerciseId: String
        public let sets: Int
        public let target: Target
        /// Numbered from 1 in order of appearance, never the sender's own label.
        public let superset: Int?

        public init(exerciseId: String, sets: Int, target: Target, superset: Int? = nil) {
            self.exerciseId = exerciseId
            self.sets = sets
            self.target = target
            self.superset = superset
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// The routine items a phone plans this from. They carry no weight, so `SessionPlanner` takes it from that phone's
    /// history. `mode` is the exercise's mode in that phone's library.
    public func routineItems(mode: (String) -> ExerciseMode?) -> [RoutineExercise] {
        items.map { item in
            let group = item.superset.map { "S\($0)" }
            switch item.target {
            case let .reps(low, high):
                return RoutineExercise(exerciseId: item.exerciseId, sets: item.sets, reps: high, repsMin: low,
                                       mode: .reps, supersetGroup: group)
            case let .seconds(seconds):
                return RoutineExercise(exerciseId: item.exerciseId, sets: item.sets, reps: 1, sec: seconds,
                                       mode: mode(item.exerciseId) == .cardio ? .cardio : .time, supersetGroup: group)
            }
        }
    }

    /// 1 to 8 ASCII letters or digits. Every library id fits; `custom-*` doesn't.
    static func isShareableId<S: StringProtocol>(_ id: S) -> Bool {
        (1...8).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
    }
}
