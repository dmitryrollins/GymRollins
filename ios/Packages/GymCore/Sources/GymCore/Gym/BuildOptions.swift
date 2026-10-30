import Foundation

/// The muscle chips on the Build workout sheet, each a set of `MuscleGroup`s.
public enum BuildMuscle: String, CaseIterable, Codable, Sendable, Identifiable {
    case chest, back, shoulders, arms, legs, core

    public var id: String { rawValue }

    public var groups: Set<MuscleGroup> {
        switch self {
        case .chest: [.chest]
        case .back: [.upperBack, .lats, .lowerBack, .traps]
        case .shoulders: [.shoulders]
        case .arms: [.biceps, .triceps, .forearms]
        case .legs: [.quads, .hamstrings, .glutes, .calves, .adductors, .abductors]
        case .core: [.abs]
        }
    }
}

/// The Build workout lengths, in minutes.
public enum BuildLength: Int, CaseIterable, Codable, Sendable {
    case short = 30, medium = 45, long = 60

    /// Exercises for this length: 30 min → 3; 45 min → 4, or 5 with two or more chips; 60 min → 6.
    public func slots(muscleCount: Int) -> Int {
        switch self {
        case .short: 3
        case .medium: muscleCount >= 2 ? 5 : 4
        case .long: 6
        }
    }
}

/// What the user asked Build workout for.
public struct BuildRequest: Sendable, Hashable {
    /// Muscle chips in the order the user picked them, without duplicates.
    public let muscles: [BuildMuscle]
    public let length: BuildLength
    /// The day being built for. It seeds tie-breaks, so the same day and input give the same workout.
    public let date: Date
    /// Exercises to avoid when anything else fits: Rebuild passes the current result's exercises. Unlike recent
    /// exercises, using one of these anyway isn't marked as a repeat.
    public let avoid: Set<String>

    public init(muscles: [BuildMuscle], length: BuildLength, date: Date, avoid: Set<String> = []) {
        self.muscles = muscles.reduce(into: []) { unique, muscle in
            if !unique.contains(muscle) { unique.append(muscle) }
        }
        self.length = length
        self.date = date
        self.avoid = avoid
    }
}
