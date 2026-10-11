import Foundation

/// The three lifts strength levels are computed for.
public enum StrengthLift: String, CaseIterable, Codable, Sendable, Identifiable {
    case squat, bench, deadlift

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .squat: "Squat"
        case .bench: "Bench press"
        case .deadlift: "Deadlift"
        }
    }

    /// Squat and deadlift load the legs: a knee/legs limits note pauses them (display only).
    public var loadsLegs: Bool { self != .bench }

    /// Library exercises that count as this lift, all at their full estimated 1RM: the competition lifts and
    /// their duplicates (POV / bar-position variants of the back squat; sumo is a legal competition deadlift).
    /// Other variants (front squat, close-grip or incline bench, RDL, …) are not mapped: their ratio to the
    /// competition lift varies too much between lifters to discount reliably.
    public var exerciseIds: [String] {
        switch self {
        case .squat: ["0043", "1461", "1462", "1435", "1436"]
        case .bench: ["0025"]
        case .deadlift: ["0032", "0117"]
        }
    }

    /// The exercise the lift's history screen opens.
    public var primaryExerciseId: String { exerciseIds[0] }

    public static func lift(forExercise id: String) -> StrengthLift? {
        allCases.first { $0.exerciseIds.contains(id) }
    }
}

/// Sex as the profile stores it (raw values are the `profiles.sex` values). Only used to pick the comparison table.
public enum ProfileSex: String, CaseIterable, Codable, Sendable, Identifiable {
    case male, female

    public var id: String { rawValue }
    public var displayName: String { self == .male ? "Male" : "Female" }
    /// Key of the standards table (OpenPowerlifting's `Sex` column).
    var tableKey: String { self == .male ? "M" : "F" }
}

/// Percentile curves of raw powerlifting competitors (`Resources/strength-standards.json`, built from
/// OpenPowerlifting by `scripts/build-strength-standards.mjs`): per sex, lift and age group, one bin per bodyweight
/// with the lift (kg) at each of `percentiles`.
public struct StrengthStandards: Decodable, Sendable {
    public struct Source: Decodable, Sendable, Equatable {
        public let name: String
        public let url: String
        public let license: String
        public let version: String
    }

    public struct AgeGroup: Decodable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let min: Int
        public let max: Int
    }

    /// A level's threshold: `fraction × the competitors' lift at percentile`.
    public struct LevelAnchor: Decodable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let percentile: Double
        public let fraction: Double
    }

    public struct Bin: Decodable, Sendable, Equatable {
        /// Median bodyweight (kg) of the bin's lifters.
        public let bw: Double
        /// Lifters of the bin's own (before pooling neighbours).
        public let n: Int
        /// kg at each of `StrengthStandards.percentiles`.
        public let kg: [Double]
    }

    public let formatVersion: Int
    public let source: Source
    public let percentiles: [Double]
    public let ageGroups: [AgeGroup]
    public let levels: [LevelAnchor]
    /// sex ("M"/"F") → lift → age group id → bins ordered by bodyweight.
    let tables: [String: [String: [String: [Bin]]]]

    public enum DecodeError: Error, Equatable {
        case unsupportedFormat(Int)
        case malformed(String)
    }

    /// Decodes and validates the bundled table.
    public static func decode(_ data: Data) throws -> StrengthStandards {
        let s = try JSONDecoder().decode(StrengthStandards.self, from: data)
        guard s.formatVersion == 1 else { throw DecodeError.unsupportedFormat(s.formatVersion) }
        guard !s.percentiles.isEmpty, s.percentiles == s.percentiles.sorted() else {
            throw DecodeError.malformed("percentiles")
        }
        guard s.levels.map(\.id) == StrengthLevel.allCases.map(\.rawValue) else { throw DecodeError.malformed("levels") }
        for (sex, lifts) in s.tables {
            for (lift, groups) in lifts {
                for (group, bins) in groups {
                    let increasing = zip(bins, bins.dropFirst()).allSatisfy { $0.bw < $1.bw }
                    if !increasing || bins.contains(where: { $0.kg.count != s.percentiles.count }) {
                        throw DecodeError.malformed("\(sex).\(lift).\(group)")
                    }
                }
            }
        }
        return s
    }

    public func ageGroup(age: Int) -> AgeGroup? {
        ageGroups.first { age >= $0.min && age <= $0.max }
    }

    /// The competitors' lift (kg) at each percentile for this sex, age and bodyweight: linear between the two bins
    /// whose median bodyweights bracket `bodyweightKg`, the end bin's curve beyond either end. Nil when the age
    /// is outside every group or the table has no bins for it.
    public func curve(sex: ProfileSex, lift: StrengthLift, age: Int, bodyweightKg: Double) -> [Double]? {
        guard let group = ageGroup(age: age),
              let bins = tables[sex.tableKey]?[lift.rawValue]?[group.id], let first = bins.first,
              let last = bins.last else { return nil }
        if bodyweightKg <= first.bw { return first.kg }
        if bodyweightKg >= last.bw { return last.kg }
        guard let upper = bins.firstIndex(where: { $0.bw >= bodyweightKg }), upper > 0 else { return first.kg }
        let lo = bins[upper - 1]
        let hi = bins[upper]
        let t = hi.bw > lo.bw ? (bodyweightKg - lo.bw) / (hi.bw - lo.bw) : 0
        return zip(lo.kg, hi.kg).map { $0 + ($1 - $0) * t }
    }

    /// Lifters in the bin nearest `bodyweightKg` (its own, before pooling), for the method sheet.
    public func lifters(sex: ProfileSex, lift: StrengthLift, age: Int, bodyweightKg: Double) -> Int? {
        guard let group = ageGroup(age: age), let bins = tables[sex.tableKey]?[lift.rawValue]?[group.id] else {
            return nil
        }
        return bins.min { abs($0.bw - bodyweightKg) < abs($1.bw - bodyweightKg) }?.n
    }
}
