import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct StrengthTextTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!

    private func report(sex: ProfileSex? = .male, birthYear: Int? = 1991, bodyweightKg: Double? = 81,
                        limits: String = "", workouts: [Workout]? = nil) throws -> StrengthReport {
        let standards = try #require(BundledStrengthStandards.shared)
        let start = now.addingTimeInterval(-7 * 86_400)
        let bench = Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "W", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: UnitConverter.toKg(130, from: .lb), reps: 10,
                                                               done: true)])
        ])
        return StrengthReport.make(standards: standards, workouts: workouts ?? [bench], sex: sex, birthYear: birthYear,
                                   bodyweightKg: bodyweightKg, limits: limits, now: now, calendar: .current)
    }

    @Test func bundledTableLoadsFromTheAppBundle() throws {
        let standards = try #require(BundledStrengthStandards.shared)
        #expect(standards.source.name == "OpenPowerlifting")
    }

    @Test func rowTextsInPoundsAndKilograms() throws {
        let bench = try #require(try report().row(.bench))
        #expect(StrengthText.detail(bench, unit: .lb) == "e1RM 173.3 lb \u{00B7} stronger than 1% of raw competitors")
        #expect(StrengthText.detail(bench, unit: .kg) == "e1RM 78.6 kg \u{00B7} stronger than 1% of raw competitors")
        #expect(StrengthText.next(bench, unit: .lb) == "+15 lb to Intermediate")
        #expect(StrengthText.next(bench, unit: .kg) == "+7 kg to Intermediate")
        #expect(StrengthText.accessibility(bench, unit: .lb)
                == "Bench press, Novice, e1RM 173.3 lb, stronger than 1% of raw competitors, +15 lb to Intermediate")
    }

    @Test func emptyAndPausedRows() throws {
        let r = try report(limits: "Knee: no leg loading")
        let squat = try #require(r.row(.squat))
        #expect(StrengthText.detail(squat, unit: .lb) == "No sets in the last 12 months")
        #expect(StrengthText.next(squat, unit: .lb) == StrengthText.paused)
        let noProfile = try #require(try report(sex: nil).row(.bench))
        #expect(StrengthText.detail(noProfile, unit: .lb) == "e1RM 173.3 lb")
        #expect(StrengthText.next(noProfile, unit: .lb) == nil)
    }

    @Test func eliteRowSaysTopLevel() throws {
        let start = now.addingTimeInterval(-86_400)
        let heavy = Workout(startedAt: start, endedAt: start, name: "W", entries: [
            WorkoutEntry(exerciseId: "0025", sets: [WorkoutSet(weightKg: 200, reps: 1, done: true)])
        ])
        let bench = try #require(try report(workouts: [heavy]).row(.bench))
        #expect(bench.assessment?.level == .elite)
        #expect(StrengthText.next(bench, unit: .lb) == "Top level")
    }

    @Test func missingMessagesAndInputs() {
        #expect(StrengthText.missing([]) == nil)
        #expect(StrengthText.missing([.profile, .bodyweight])?.hasPrefix("Add your sex and birth year") == true)
        #expect(StrengthText.missing([.bodyweight]) == "Add a weigh-in to see your levels.")
        #expect(StrengthText.inputs(sex: .male, age: 35, bodyweightKg: 81, unit: .lb) == "Male, 35 \u{00B7} 178.6 lb")
        #expect(StrengthText.inputs(sex: nil, age: nil, bodyweightKg: nil, unit: .kg)
                == "Sex and birth year not set \u{00B7} no weigh-in")
    }
}
