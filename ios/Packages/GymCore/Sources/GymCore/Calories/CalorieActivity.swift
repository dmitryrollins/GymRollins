import Foundation

/// Workout-wide effort, from logged RPE/RIR or rest density (`EffortRule`).
public enum EffortLevel: String, Codable, Sendable, CaseIterable {
    case light, moderate, vigorous
}

/// The kind of cardio an exercise is, for picking its Compendium activity and the Health workout type.
public enum CardioKind: String, Codable, Sendable, CaseIterable {
    case running, walking, inclineWalking, cycling, elliptical, stairs, jumpRope, rowing, skiErg, armErgometer
    case bodyweightIntervals, other

    public var healthActivity: HealthActivityKind {
        switch self {
        case .running: .running
        case .walking, .inclineWalking: .walking
        case .cycling: .cycling
        case .elliptical: .elliptical
        case .stairs: .stairClimbing
        case .jumpRope: .jumpRope
        case .rowing: .rowing
        case .bodyweightIntervals: .hiit
        case .skiErg, .armErgometer, .other: .mixedCardio
        }
    }
}

/// The workout type written to Apple Health: strength for any session with strength work, else its main cardio.
public enum HealthActivityKind: String, Codable, Sendable, CaseIterable {
    case strength, running, walking, cycling, elliptical, stairClimbing, jumpRope, rowing, hiit, mixedCardio
}

/// What an entry's time is spent on, mapped to 2024 Compendium codes by effort (see plan 15).
public enum CalorieActivity: Hashable, Sendable, CaseIterable {
    case weights, squatDeadlift, supersetWeights, circuit, calisthenics
    case cardio(CardioKind)

    public static var allCases: [CalorieActivity] {
        [.weights, .squatDeadlift, .supersetWeights, .circuit, .calisthenics] + CardioKind.allCases.map(Self.cardio)
    }

    /// Every code any activity can pick at any effort.
    public static var allCodes: [String] {
        Array(Set(allCases.flatMap { a in EffortLevel.allCases.map { a.code(effort: $0) } })).sorted()
    }

    public var isCardio: Bool {
        if case .cardio = self { return true }
        return false
    }

    public func code(effort: EffortLevel) -> String {
        switch self {
        case .weights: effort == .vigorous ? "02050" : "02054"
        case .squatDeadlift: Self.pick(effort, light: "02054", moderate: "02052", vigorous: "02050")
        case .supersetWeights: "02055"
        case .circuit: Self.pick(effort, light: "02034", moderate: "02035", vigorous: "02040")
        case .calisthenics: Self.pick(effort, light: "02024", moderate: "02022", vigorous: "02020")
        case .cardio(let kind): Self.cardioCode(kind, effort: effort)
        }
    }

    private static func cardioCode(_ kind: CardioKind, effort: EffortLevel) -> String {
        let vigorous = effort == .vigorous
        switch kind {
        case .running: return "12150"
        case .walking: return "17200"
        case .inclineWalking: return "17035"
        case .cycling: return "01200"
        case .elliptical: return vigorous ? "02049" : "02048"
        case .stairs: return "02065"
        case .jumpRope: return "02068"
        case .rowing: return vigorous ? "02070" : "02071"
        case .skiErg: return "02080"
        case .armErgometer: return "02115"
        case .bodyweightIntervals: return vigorous ? "02214" : "02210"
        case .other: return "02060"
        }
    }

    private static func pick(_ effort: EffortLevel, light: String, moderate: String, vigorous: String) -> String {
        switch effort {
        case .light: light
        case .moderate: moderate
        case .vigorous: vigorous
        }
    }
}

/// Maps a library exercise (body part, equipment, name) onto a `CalorieActivity`.
public enum ActivityClassifier {
    private static let intervalWords = ["burpee", "jump", "jack", "climber", "hop", "knee", "crawl", "skater"]

    /// `sets` decide for an unknown exercise: logged minutes/distance → cardio, weight → weights, else calisthenics.
    public static func activity(for exercise: Exercise?, sets: [WorkoutSet]) -> CalorieActivity {
        guard let exercise else {
            if sets.contains(where: { ($0.minutes ?? 0) > 0 || ($0.distanceM ?? 0) > 0 }) { return .cardio(.other) }
            return sets.contains { $0.weightKg > 0 } ? .weights : .calisthenics
        }
        if exercise.mode == .cardio || exercise.bodyPart == "cardio" { return .cardio(cardioKind(exercise)) }
        if exercise.equipment == "body weight" { return .calisthenics }
        let name = exercise.name.lowercased()
        return name.contains("squat") || name.contains("deadlift") ? .squatDeadlift : .weights
    }

    static func cardioKind(_ exercise: Exercise) -> CardioKind {
        let text = "\(exercise.name) \(exercise.equipment)".lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("jump rope", "skipping") { return .jumpRope }
        if has("stepmill", "stair") { return .stairs }
        if has("elliptical", "cross trainer") { return .elliptical }
        if has("skierg", "ski erg") { return .skiErg }
        if has("upper body ergometer", "arm ergometer") { return .armErgometer }
        if has("rowing", "rower", "row erg") { return .rowing }
        if has("bike", "cycle", "cycling", "bicycle") { return .cycling }
        if has("incline") && has("walk", "treadmill") { return .inclineWalking }
        if has("walk") { return .walking }
        if has("run", "jog", "sprint") { return .running }
        if exercise.equipment == "body weight" || intervalWords.contains(where: text.contains) {
            return .bodyweightIntervals
        }
        return .other
    }
}

/// Effort thresholds (plan 15): mean RPE ≥ 8.5 vigorous, ≥ 6 moderate; rest density ≤ 1.5 min per working set
/// vigorous, ≤ 4 moderate.
public enum EffortRule {
    public static func fromRPE(_ rpe: Double) -> EffortLevel {
        rpe >= 8.5 ? .vigorous : rpe >= 6 ? .moderate : .light
    }

    public static func fromDensity(minutesPerSet: Double) -> EffortLevel {
        minutesPerSet <= 1.5 ? .vigorous : minutesPerSet <= 4 ? .moderate : .light
    }

    /// RPE, or 10 − RIR, for sets that have either.
    static func rpe(_ set: WorkoutSet) -> Double? {
        if let rpe = set.rpe { return rpe }
        return set.rir.map { 10 - $0 }
    }
}
