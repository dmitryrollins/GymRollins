import Foundation
import GymCore

/// Strings the strength-level card, rows and sheets show (pure, unit-tested in `StrengthTextTests`).
enum StrengthText {
    static let privacy = "Used only to compare your lifts with lifters like you."
    static let paused = "Paused \u{2014} injury note"
    static let credit = "Strength standards derived from OpenPowerlifting data, public domain."

    /// "173 lb" in the user's unit.
    static func weight(_ kg: Double, unit: WeightUnit) -> String {
        WeightFormatter.format(kg: kg, unit: unit, includeSecondary: false)
    }

    /// "e1RM 173 lb · stronger than 1% of raw competitors" / "e1RM 173 lb" / "No sets in the last 12 months".
    static func detail(_ row: StrengthRow, unit: WeightUnit) -> String {
        guard let estimate = row.estimate else { return "No sets in the last 12 months" }
        let e1RM = "e1RM \(weight(estimate.e1RMKg, unit: unit))"
        guard let a = row.assessment else { return e1RM }
        return "\(e1RM) \u{00B7} stronger than \(a.percentileText) of raw competitors"
    }

    /// "+15 lb to Intermediate", "Top level", the paused note, or nil (no level to show).
    static func next(_ row: StrengthRow, unit: WeightUnit) -> String? {
        if row.paused { return paused }
        guard let a = row.assessment else { return nil }
        guard let next = a.next, let gap = a.gapKg else { return "Top level" }
        return "\(StrengthGap.text(kg: gap, unit: unit)) to \(next.displayName)"
    }

    /// VoiceOver: "Bench press, Novice, e1RM 173 lb, stronger than 1% of raw competitors, +15 lb to Intermediate".
    static func accessibility(_ row: StrengthRow, unit: WeightUnit) -> String {
        [row.lift.displayName, row.assessment?.level.displayName, detail(row, unit: unit)
            .replacingOccurrences(of: " \u{00B7} ", with: ", "), next(row, unit: unit)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Why levels aren't shown, or nil when nothing is missing.
    static func missing(_ missing: [StrengthMissing]) -> String? {
        if missing.contains(.profile) {
            return "Add your sex and birth year to compare your lifts with raw powerlifters of your sex, age and "
                + "bodyweight."
        }
        if missing.contains(.bodyweight) { return "Add a weigh-in to see your levels." }
        return nil
    }

    /// "Male, 35 · 81 kg" — the inputs the method sheet shows.
    static func inputs(sex: ProfileSex?, age: Int?, bodyweightKg: Double?, unit: WeightUnit) -> String {
        let who = [sex?.displayName, age.map { "\($0)" }].compactMap { $0 }.joined(separator: ", ")
        let bw = bodyweightKg.map { weight($0, unit: unit) }
        return [who.isEmpty ? "Sex and birth year not set" : who, bw ?? "no weigh-in"]
            .joined(separator: " \u{00B7} ")
    }
}
