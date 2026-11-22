/// Apple's effort words for a workout (plan 40, spec §4), as Fitness and the Apple Watch use them: 1–3 Easy, 4–6
/// Moderate, 7–8 Hard, 9–10 All Out. Not `EffortLevel`, the calorie estimate's light / moderate / vigorous.
public enum WorkoutEffortLevel: String, Sendable, CaseIterable {
    case easy, moderate, hard, allOut

    /// The word for a score; nil outside 1...10.
    public static func level(for score: Int) -> WorkoutEffortLevel? {
        switch score {
        case 1...3: .easy
        case 4...6: .moderate
        case 7...8: .hard
        case 9...10: .allOut
        default: nil
        }
    }

    public var title: String {
        switch self {
        case .easy: "Easy"
        case .moderate: "Moderate"
        case .hard: "Hard"
        case .allOut: "All Out"
        }
    }
}

/// A workout's effort (plan 40, decision 10): a rating, made in GymRollins or in Fitness, or the Apple Watch's
/// estimate. `WorkoutMeasuredRules` decides which one a workout shows.
public struct Effort: Equatable, Sendable {
    public static let range: ClosedRange<Int> = MeasurementLimits.effort

    public let score: Int
    /// The Apple Watch's estimate rather than anyone's rating: the card adds "· Estimated".
    public let estimated: Bool

    /// Nil outside `range`: a score from Health or a stored row that doesn't fit is dropped, never clamped.
    public init?(score: Int, estimated: Bool) {
        guard Self.range.contains(score) else { return nil }
        self.score = score
        self.estimated = estimated
    }

    public var level: WorkoutEffortLevel {
        // `score` is always inside `range`, and `level(for:)` covers all of it.
        WorkoutEffortLevel.level(for: score) ?? .allOut
    }
}
