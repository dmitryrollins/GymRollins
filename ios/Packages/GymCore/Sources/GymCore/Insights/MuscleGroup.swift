import Foundation

/// The 16 display groups the recovery map, weekly set targets and Claude's insights use. Raw values are the stable
/// ids stored in `muscle_targets.muscle` and returned by the MCP server.
public enum MuscleGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case chest, shoulders, traps
    case upperBack = "upper_back"
    case lats
    case lowerBack = "lower_back"
    case biceps, triceps, forearms, abs, glutes, quads, hamstrings, calves, adductors, abductors

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chest: "Chest"
        case .shoulders: "Shoulders"
        case .traps: "Traps"
        case .upperBack: "Upper back"
        case .lats: "Lats"
        case .lowerBack: "Lower back"
        case .biceps: "Biceps"
        case .triceps: "Triceps"
        case .forearms: "Forearms"
        case .abs: "Abs"
        case .glutes: "Glutes"
        case .quads: "Quads"
        case .hamstrings: "Hamstrings"
        case .calves: "Calves"
        case .adductors: "Adductors"
        case .abductors: "Abductors"
        }
    }

    /// Large groups (default weekly target 10–20 hard sets); the rest are small (6–12).
    public var isMajor: Bool {
        switch self {
        case .chest, .shoulders, .upperBack, .lats, .glutes, .quads, .hamstrings: true
        default: false
        }
    }

    public var isLeg: Bool { Self.legs.contains(self) }

    public static let legs: Set<MuscleGroup> = [.glutes, .quads, .hamstrings, .calves, .adductors, .abductors]

    public var defaultTarget: SetTargetRange {
        isMajor ? SetTargetRange(min: 10, max: 20) : SetTargetRange(min: 6, max: 12)
    }

    /// Defaults for every group.
    public static var defaultTargets: [MuscleGroup: SetTargetRange] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultTarget) })
    }
}

/// Weekly hard-set target range for one muscle group (inclusive).
public struct SetTargetRange: Codable, Sendable, Hashable {
    public let min: Int
    public let max: Int

    public init(min: Int, max: Int) {
        self.min = min
        self.max = max
    }

    /// Within `DomainLimits.weeklySetTarget` and `min ≤ max` (the database CHECK).
    public var isValid: Bool {
        DomainLimits.weeklySetTarget.contains(min) && DomainLimits.weeklySetTarget.contains(max) && min <= max
    }

    /// "10–20", or "8" when both ends match.
    public var text: String { min == max ? "\(min)" : "\(min)\u{2013}\(max)" }
}
