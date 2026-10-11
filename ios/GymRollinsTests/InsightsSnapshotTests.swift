import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct InsightsSnapshotTests {
    private let library = ExerciseLibrary(exercises: [
        Exercise(id: "0025", name: "barbell bench press", bodyPart: "chest", equipment: "barbell", target: "pectorals",
                 secondary: ["triceps", "shoulders"]),
        Exercise(id: "0198", name: "cable pulldown", bodyPart: "back", equipment: "cable", target: "lats",
                 secondary: ["biceps", "forearms"]),
    ])
    private let now = ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!
    private let utc = TrainingWeek.calendar(timeZone: TimeZone(identifier: "UTC")!)

    private func workout(_ iso: String, _ id: String, sets: Int = 3) -> Workout {
        let start = ISO8601DateFormatter().date(from: iso)!
        return Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "W", entries: [
            WorkoutEntry(exerciseId: id, sets: (0..<sets).map { _ in WorkoutSet(weightKg: 60, reps: 8, done: true) }),
        ])
    }

    private func snapshot(_ recent: [Workout], limits: String = "", targets: [MuscleGroup: SetTargetRange] = [:],
                          trainingDays: Int = 3, extraDates: [Date] = []) -> InsightsSnapshot {
        InsightsSnapshot.make(recent: recent, startDates: recent.map(\.startedAt) + extraDates,
                              targets: MuscleGroup.defaultTargets.merging(targets) { $1 },
                              profile: Profile(trainingDays: trainingDays, limits: limits), library: library,
                              now: now, calendar: utc)
    }

    @Test func emptyHistory() {
        let s = snapshot([])
        #expect(s.summaryLine == "All muscles fresh")
        #expect(s.freshLine == nil)
        #expect(s.streak.current == 0)
        #expect(s.weeklyRows.map(\.group) == MuscleGroup.allCases.filter(\.isMajor))
        #expect(s.streakChipText == "0 wk")
    }

    @Test func summaryFreshLineAndLabels() {
        let s = snapshot([workout("2026-09-26T07:00:00Z", "0025", sets: 4), workout("2026-09-20T10:00:00Z", "0198")])
        #expect(s.recovery(of: .chest).status == .fatigued)
        #expect(s.summaryLine == "1 fatigued \u{00B7} 2 recovering")
        #expect(s.freshLine == "Fresh: lats, biceps, forearms")
        #expect(s.regionLabel(.chest) == "Chest, \(s.recovery(of: .chest).percent)% recovered")
        #expect(s.regionLabel(.lats) == "Lats, 100% recovered")
    }

    @Test func limitedLegsAreLabelledAndLeftOutOfFresh() {
        let s = snapshot([], limits: "Knee: no leg loading until ~26 Oct 2026")
        #expect(s.limited == MuscleGroup.legs)
        #expect(s.regionLabel(.quads) == "Quads, 100% recovered, limited by your injury note")
    }

    @Test func weeklyRowsAndSummaryLines() {
        let s = snapshot([workout("2026-09-21T18:00:00Z", "0025", sets: 4)],
                         targets: [.chest: SetTargetRange(min: 12, max: 16)])
        #expect(s.weeklyRows.first?.group == .chest)
        #expect(s.weeklyRows.contains { $0.group == .triceps })
        #expect(s.weeklyLine(.chest) == "Chest 4/12\u{2013}16 this week")
        #expect(s.weeklyLine(.triceps) == "Triceps 2/6\u{2013}12 this week")
        #expect(s.weekLabel == "21\u{2013}27 Sep")
    }

    @Test func weeklyAccessibilityText() {
        let s = snapshot([workout("2026-09-21T18:00:00Z", "0025", sets: 12)])
        let chest = s.weekly.first { $0.group == .chest }!
        #expect(InsightsSnapshot.weeklyAccessibility(chest) == "Chest, 12 of 10 to 20 sets this week, in range")
        let lats = s.weekly.first { $0.group == .lats }!
        #expect(InsightsSnapshot.weeklyAccessibility(lats) == "Lats, 0 of 10 to 20 sets this week, below target")
    }

    @Test func streakUsesTrainingDaysAsGoal() {
        let lastWeek = ["2026-09-14", "2026-09-15", "2026-09-16"].map { ISO8601DateFormatter().date(from: "\($0)T10:00:00Z")! }
        let s = snapshot([workout("2026-09-21T18:00:00Z", "0025")], trainingDays: 3, extraDates: lastWeek)
        #expect(s.streak.goal == 3)
        #expect(s.streak.current == 1)
        #expect(s.streak.thisWeekDays == 1)
        #expect(s.streakChipText == "1 wk")
        #expect(s.streakAccessibility == "Weekly streak: 1 week. 1 of 3 workouts this week.")
    }
}
