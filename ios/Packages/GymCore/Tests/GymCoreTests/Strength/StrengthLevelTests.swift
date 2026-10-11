import Foundation
import Testing
@testable import GymCore

struct StrengthStandardsTests {
    @Test func bundledTableDecodesWithEveryLiftSexAndAgeGroup() throws {
        let s = try StrengthFixture.bundled()
        #expect(s.source.name == "OpenPowerlifting")
        #expect(s.levels.map(\.id) == StrengthLevel.allCases.map(\.rawValue))
        for sex in ProfileSex.allCases {
            for lift in StrengthLift.allCases {
                for group in s.ageGroups {
                    let curve = try #require(s.curve(sex: sex, lift: lift, age: group.min, bodyweightKg: 70))
                    #expect(curve.count == s.percentiles.count)
                    #expect(curve == curve.sorted(), "\(sex) \(lift) \(group.id)")
                }
            }
        }
    }

    @Test func decodeRejectsUnknownFormatsBadLevelsAndShortCurves() {
        #expect(throws: StrengthStandards.DecodeError.unsupportedFormat(2)) {
            try StrengthStandards.decode(StrengthFixture.synthetic(formatVersion: 2))
        }
        #expect(throws: StrengthStandards.DecodeError.malformed("levels")) {
            try StrengthStandards.decode(StrengthFixture.synthetic(levels: "[]"))
        }
        #expect(throws: StrengthStandards.DecodeError.malformed("M.bench.open")) {
            try StrengthStandards.decode(StrengthFixture.synthetic(kg60: "[1, 2]"))
        }
        // Two curves at one bodyweight (or out of order) would make levels jump there.
        #expect(throws: StrengthStandards.DecodeError.malformed("M.bench.open")) {
            try StrengthStandards.decode(StrengthFixture.synthetic(bw60: 100))
        }
    }

    @Test func curveInterpolatesBetweenBinsAndClampsAtTheEnds() throws {
        let s = try StrengthFixture.syntheticStandards()
        #expect(s.curve(sex: .male, lift: .bench, age: 30, bodyweightKg: 80) == [60, 90, 110, 140, 180])
        #expect(s.curve(sex: .male, lift: .bench, age: 30, bodyweightKg: 40) == [50, 80, 100, 130, 160])
        #expect(s.curve(sex: .male, lift: .bench, age: 30, bodyweightKg: 150) == [70, 100, 120, 150, 200])
        // No table for this sex/lift/age group.
        #expect(s.curve(sex: .female, lift: .bench, age: 30, bodyweightKg: 60) == nil)
        #expect(s.curve(sex: .male, lift: .squat, age: 30, bodyweightKg: 60) == nil)
        #expect(s.curve(sex: .male, lift: .bench, age: 20, bodyweightKg: 60) == nil) // u23 has no bins here
        #expect(s.curve(sex: .male, lift: .bench, age: 45, bodyweightKg: 60) == nil) // no such group
        #expect(s.lifters(sex: .male, lift: .bench, age: 30, bodyweightKg: 90) == 50)
    }

    @Test func ageGroupBoundaries() throws {
        let s = try StrengthFixture.bundled()
        #expect(s.ageGroup(age: 13) == nil)
        #expect(s.ageGroup(age: 14)?.id == "u23")
        #expect(s.ageGroup(age: 22)?.id == "u23")
        #expect(s.ageGroup(age: 23)?.id == "open")
        #expect(s.ageGroup(age: 39)?.id == "open")
        #expect(s.ageGroup(age: 40)?.id == "m40")
        #expect(s.ageGroup(age: 60)?.id == "m60")
        #expect(s.ageGroup(age: 95)?.id == "m60")
    }

    @Test func liftMappingCoversCompetitionLiftsOnly() {
        #expect(StrengthLift.lift(forExercise: "0043") == .squat)
        #expect(StrengthLift.lift(forExercise: "1435") == .squat)
        #expect(StrengthLift.lift(forExercise: "0025") == .bench)
        #expect(StrengthLift.lift(forExercise: "0117") == .deadlift)
        #expect(StrengthLift.lift(forExercise: "0042") == nil) // front squat
        #expect(StrengthLift.lift(forExercise: "0030") == nil) // close-grip bench
        #expect(StrengthLift.lift(forExercise: "0085") == nil) // RDL
        #expect(StrengthLift.bench.primaryExerciseId == "0025")
        #expect(StrengthLift.squat.loadsLegs && StrengthLift.deadlift.loadsLegs && !StrengthLift.bench.loadsLegs)
    }
}

struct StrengthLevelCalculatorTests {
    private func assess(_ kg: Double, bw: Double = 60) throws -> StrengthAssessment {
        try #require(StrengthLevelCalculator.assess(standards: StrengthFixture.syntheticStandards(), lift: .bench,
                                                    e1RMKg: kg, bodyweightKg: bw, sex: .male, age: 30))
    }

    @Test func thresholdsAnchorOnTheCompetitorCurve() throws {
        let a = try assess(70)
        #expect(a.thresholds == [.beginner: 0, .novice: 45, .intermediate: 65, .advanced: 80, .elite: 130])
    }

    @Test func exactlyOnAThresholdReachesTheLevel() throws {
        #expect(try assess(44.99).level == .beginner)
        #expect(try assess(45).level == .novice)
        #expect(try assess(65).level == .intermediate)
        #expect(try assess(80).level == .advanced)
        #expect(try assess(129.99).level == .advanced)
        #expect(try assess(130).level == .elite)
        #expect(try assess(500).level == .elite)
        // A threshold reached through lb entry (float noise from the conversion) still counts.
        #expect(try assess(UnitConverter.toKg(UnitConverter.fromKg(45, to: .lb), from: .lb)).level == .novice)
    }

    @Test func nextLevelTargetGapAndProgress() throws {
        let a = try assess(70)
        #expect(a.level == .intermediate)
        #expect(a.next == .advanced)
        #expect(a.nextTargetKg == 80)
        #expect(a.gapKg == 10)
        #expect(abs(a.progress - 5.0 / 15.0) < 1e-9)
        let elite = try assess(140)
        #expect(elite.next == nil && elite.nextTargetKg == nil && elite.gapKg == nil && elite.progress == 1)
        let beginner = try assess(9)
        #expect(beginner.progress == 0.2)
    }

    @Test func percentileInterpolatesAndClamps() throws {
        #expect(try assess(100).percentile == 50)
        #expect(try assess(115).percentile == 65)
        #expect(try assess(25).percentile == 0.5)
        #expect(try assess(25).percentileText == "under 1%")
        #expect(try assess(50).percentileText == "1%")
        #expect(try assess(115).percentileText == "65%")
        #expect(try assess(160).percentile == 100)
        #expect(try assess(160).percentileText == "over 99%")
        #expect(try assess(159).percentileText == "98%")
    }

    @Test func bodyweightInterpolation() throws {
        let a = try assess(90, bw: 80) // curve at 80 kg: 60/90/110/140/180
        #expect(a.percentile == 20)
        #expect(a.thresholds[.advanced] == 90)
        #expect(a.level == .advanced)
    }

    @Test func invalidInputsGiveNil() throws {
        let s = try StrengthFixture.syntheticStandards()
        #expect(StrengthLevelCalculator.assess(standards: s, lift: .bench, e1RMKg: 0, bodyweightKg: 60, sex: .male,
                                               age: 30) == nil)
        #expect(StrengthLevelCalculator.assess(standards: s, lift: .bench, e1RMKg: 50, bodyweightKg: 0, sex: .male,
                                               age: 30) == nil)
        #expect(StrengthLevelCalculator.assess(standards: s, lift: .bench, e1RMKg: 50, bodyweightKg: 60, sex: .male,
                                               age: 10) == nil)
    }

    @Test func gapTextRoundsUpInTheUsersUnit() {
        #expect(StrengthGap.text(kg: 7.6, unit: .lb) == "+17.5 lb") // 16.76 lb
        #expect(StrengthGap.text(kg: 7.6, unit: .kg) == "+8 kg")
        #expect(StrengthGap.text(kg: 7.2, unit: .kg) == "+7.5 kg")
        #expect(StrengthGap.text(kg: UnitConverter.toKg(5, from: .lb), unit: .lb) == "+5 lb") // exact, not 7.5
        #expect(StrengthGap.text(kg: 0.01, unit: .lb) == "+2.5 lb")
        #expect(StrengthGap.text(kg: 0.01, unit: .kg) == "+0.5 kg")
    }
}

struct StrengthReportTests {
    private let now = StrengthFixture.date("2026-09-29T12:00:00Z")

    private func report(_ workouts: [Workout], sex: ProfileSex? = .male, birthYear: Int? = 1991,
                        bodyweightKg: Double? = 81, limits: String = "") throws -> StrengthReport {
        StrengthReport.make(standards: try StrengthFixture.bundled(), workouts: workouts, sex: sex,
                            birthYear: birthYear, bodyweightKg: bodyweightKg, limits: limits, now: now,
                            calendar: StrengthFixture.utc())
    }

    /// Bench 130 lb x 10 (Epley 78.6 kg), 81 kg, male, 35: the plan's worked example.
    private var ownerBench: Workout {
        StrengthFixture.workout("2026-09-19T10:00:00Z", "0025", kg: UnitConverter.toKg(130, from: .lb), reps: 10)
    }

    @Test func ownerExampleReadsNoviceWithTheGapToIntermediate() throws {
        let r = try report([ownerBench])
        #expect(r.missing.isEmpty)
        #expect(r.age == 35)
        let bench = try #require(r.row(.bench)?.assessment)
        #expect(abs(bench.e1RMKg - 78.62) < 0.01)
        #expect(bench.level == .novice)
        #expect(bench.next == .intermediate)
        #expect(abs(try #require(bench.nextTargetKg) - 85.2) < 0.05)
        #expect(StrengthGap.text(kg: try #require(bench.gapKg), unit: .lb) == "+15 lb") // 14.4 lb
        #expect(bench.percentileText == "1%")
        #expect(r.row(.squat)?.estimate == nil && r.row(.squat)?.assessment == nil)
    }

    /// Birth years are Gregorian (what the server stores and OpenPowerlifting uses) whatever the device calendar.
    @Test func ageAndBirthYearChoicesUseGregorianYearsOnAnyDeviceCalendar() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "UTC")!
        #expect(StrengthReport.age(birthYear: 1991, now: now, calendar: buddhist) == 35)
        let r = StrengthReport.make(standards: try StrengthFixture.bundled(), workouts: [ownerBench], sex: .male,
                                    birthYear: 1991, bodyweightKg: 81, limits: "", now: now, calendar: buddhist)
        #expect(r.age == 35 && r.missing.isEmpty)
        let years = StrengthReport.birthYears(now: now, calendar: buddhist)
        #expect(years.first == 2012) // 14 this year
        #expect(years.last == 1926) // 100 this year
        #expect(years == years.sorted(by: >))
        #expect(StrengthReport.birthYears(now: now, calendar: StrengthFixture.utc()) == years)
    }

    @Test func missingProfileOrBodyweightKeepsEstimatesButNoLevels() throws {
        let noSex = try report([ownerBench], sex: nil)
        #expect(noSex.missing == [.profile])
        #expect(noSex.row(.bench)?.estimate != nil)
        #expect(noSex.row(.bench)?.assessment == nil)
        #expect(try report([ownerBench], birthYear: nil).missing == [.profile])
        #expect(try report([ownerBench], birthYear: 2015).missing == [.profile]) // 11: under the table's 14
        #expect(try report([ownerBench], birthYear: 2012).missing.isEmpty) // 14
        #expect(try report([ownerBench], bodyweightKg: nil).missing == [.bodyweight])
        #expect(try report([], sex: nil, bodyweightKg: nil).missing == [.profile, .bodyweight])
    }

    @Test func bestEstimateUsesTheWindowMappedExercisesAndWorkingSetsOnly() throws {
        let workouts = [
            StrengthFixture.workout("2025-09-28T10:00:00Z", "0032", kg: 250, reps: 1), // 366 days ago: out
            StrengthFixture.workout("2026-10-05T10:00:00Z", "0032", kg: 240, reps: 1), // future: out
            StrengthFixture.workout("2026-09-01T10:00:00Z", "0032", kg: 300, reps: 1, warmup: true), // warm-up
            StrengthFixture.workout("2026-09-02T10:00:00Z", "0032", kg: 290, reps: 1, done: false), // not done
            StrengthFixture.workout("2026-09-03T10:00:00Z", "0085", kg: 200, reps: 1), // RDL: not mapped
            StrengthFixture.workout("2026-08-01T10:00:00Z", "0032", kg: 150, reps: 1),
            StrengthFixture.workout("2026-09-10T10:00:00Z", "0117", kg: 160, reps: 1) // sumo counts
        ]
        let best = try #require(StrengthReport.best(workouts: workouts, lift: .deadlift, now: now))
        #expect(best == LiftEstimate(e1RMKg: 160, date: StrengthFixture.date("2026-09-10T10:00:00Z"),
                                     exerciseId: "0117"))
        // Ties keep the most recent session.
        let tie = [StrengthFixture.workout("2026-09-01T10:00:00Z", "0043", kg: 100, reps: 1),
                   StrengthFixture.workout("2026-09-05T10:00:00Z", "1435", kg: 100, reps: 1)]
        #expect(StrengthReport.best(workouts: tie, lift: .squat, now: now)?.exerciseId == "1435")
        // Over 12 reps gives no estimate.
        #expect(StrengthReport.best(workouts: [StrengthFixture.workout("2026-09-01T10:00:00Z", "0025", kg: 40,
                                                                        reps: 20)], lift: .bench, now: now) == nil)
    }

    @Test func kneeNotePausesLegLiftsWithoutHidingNumbers() throws {
        let squat = StrengthFixture.workout("2026-09-10T10:00:00Z", "0043", kg: 100, reps: 5)
        let r = try report([squat, ownerBench], limits: "Knee: no leg loading until ~26 Oct 2026")
        #expect(r.row(.squat)?.paused == true)
        #expect(r.row(.deadlift)?.paused == true)
        #expect(r.row(.bench)?.paused == false)
        #expect(r.row(.squat)?.assessment != nil)
        #expect(try report([squat]).row(.squat)?.paused == false)
    }

    @Test func femaleAndOlderAgeGroupTablesAreEasierAtTheSameLift() throws {
        let bench = StrengthFixture.workout("2026-09-10T10:00:00Z", "0025", kg: 60, reps: 1)
        let man = try #require(try report([bench], bodyweightKg: 63).row(.bench)?.assessment)
        let woman = try #require(try report([bench], sex: .female, bodyweightKg: 63).row(.bench)?.assessment)
        let older = try #require(try report([bench], birthYear: 1961, bodyweightKg: 63).row(.bench)?.assessment)
        #expect(woman.percentile > man.percentile)
        #expect(woman.level > man.level)
        #expect(older.percentile > man.percentile)
    }
}
