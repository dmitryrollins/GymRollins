import Foundation
import GymCore
import GymData

/// Everything the recovery map, weekly-sets bars and streak chip show, computed once from recent workouts.
struct InsightsSnapshot: Equatable {
    /// Workouts this far back feed the map (recovery, recent sets, the "rotation" of trained groups).
    static let windowDays = 28

    let recovery: [MuscleRecovery]
    let limited: Set<MuscleGroup>
    let fresh: [MuscleGroup]
    let weekly: [WeeklyMuscleSets]
    let week: DateInterval
    let streak: Streak
    /// Groups trained within the window.
    let rotation: Set<MuscleGroup>
    let timeZone: TimeZone

    static func make(recent: [Workout], startDates: [Date], targets: [MuscleGroup: SetTargetRange], profile: Profile,
                     library: ExerciseLibrary, now: Date, calendar: Calendar) -> InsightsSnapshot {
        let lookup: (String) -> Exercise? = { library.exercise($0) }
        let recovery = RecoveryModel.compute(workouts: recent, exercise: lookup, now: now)
        let limited = LimitedMuscles.from(limits: profile.limits)
        let week = TrainingWeek.interval(containing: now, calendar: calendar)
        let counts = WeeklySets.count(workouts: recent, exercise: lookup, week: week)
        let since = now.addingTimeInterval(-Double(windowDays) * 86_400)
        return InsightsSnapshot(
            recovery: recovery, limited: limited,
            fresh: RecoveryModel.freshest(recovery, limited: limited, now: now, rotationDays: windowDays),
            weekly: WeeklySets.progress(counts: counts, targets: targets), week: week,
            streak: StreakCalculator.compute(workoutDates: startDates, goal: profile.trainingDays, now: now,
                                             calendar: calendar),
            rotation: Set(recovery.filter { ($0.lastTrained ?? .distantPast) >= since }.map(\.group)),
            timeZone: calendar.timeZone)
    }

    static let empty = InsightsSnapshot(
        recovery: MuscleGroup.allCases.map { MuscleRecovery(group: $0, percent: 100, fatigue: 0, lastTrained: nil,
                                                            recoveredAt: nil) },
        limited: [], fresh: [], weekly: WeeklySets.progress(counts: [:], targets: [:]),
        week: DateInterval(start: .distantPast, duration: 7 * 86_400),
        streak: Streak(current: 0, longest: 0, goal: 4, thisWeekDays: 0, thisWeekMet: false), rotation: [],
        timeZone: .current)

    func recovery(of group: MuscleGroup) -> MuscleRecovery {
        recovery.first { $0.group == group }
            ?? MuscleRecovery(group: group, percent: 100, fatigue: 0, lastTrained: nil, recoveredAt: nil)
    }

    // MARK: Recovery text

    /// "All muscles fresh", or "2 fatigued · 3 recovering".
    var summaryLine: String {
        let fatigued = recovery.filter { $0.status == .fatigued }.count
        let recovering = recovery.filter { $0.status == .recovering }.count
        let parts = [fatigued > 0 ? "\(fatigued) fatigued" : nil, recovering > 0 ? "\(recovering) recovering" : nil]
            .compactMap { $0 }
        return parts.isEmpty ? "All muscles fresh" : parts.joined(separator: " \u{00B7} ")
    }

    /// "Fresh: lats, biceps" — nil when nothing in the rotation is fresh.
    var freshLine: String? {
        fresh.isEmpty ? nil : "Fresh: " + fresh.map { $0.displayName.lowercased() }.joined(separator: ", ")
    }

    /// VoiceOver label for a map region / row: "Chest, 80% recovered".
    func regionLabel(_ group: MuscleGroup) -> String {
        let base = "\(group.displayName), \(recovery(of: group).percent)% recovered"
        return limited.contains(group) ? base + ", limited by your injury note" : base
    }

    // MARK: Weekly sets

    /// Groups worth a bar: trained this week or in the rotation; the major groups when there's no history.
    var weeklyRows: [WeeklyMuscleSets] {
        let shown = weekly.filter { $0.sets > 0 || rotation.contains($0.group) }
        return shown.isEmpty ? weekly.filter(\.group.isMajor) : shown
    }

    /// "Chest 12/10–20 this week" (Summary).
    func weeklyLine(_ group: MuscleGroup) -> String {
        let row = weekly.first { $0.group == group } ?? WeeklyMuscleSets(group: group, sets: 0, target: group.defaultTarget)
        return "\(group.displayName) \(WeeklySets.format(row.sets))/\(row.target.text) this week"
    }

    static func weeklyAccessibility(_ row: WeeklyMuscleSets) -> String {
        let status = switch row.status {
        case .below: "below target"
        case .within: "in range"
        case .above: "above target"
        }
        return "\(row.group.displayName), \(WeeklySets.format(row.sets)) of \(row.target.min) to \(row.target.max) "
            + "sets this week, \(status)"
    }

    /// "21–27 Sep", or "28 Sep – 4 Oct" across months.
    var weekLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        let last = week.end.addingTimeInterval(-1)
        formatter.dateFormat = "MMM"
        let sameMonth = formatter.string(from: week.start) == formatter.string(from: last)
        formatter.dateFormat = "d"
        let startDay = formatter.string(from: week.start)
        formatter.dateFormat = "d MMM"
        return sameMonth ? "\(startDay)\u{2013}\(formatter.string(from: last))"
            : "\(formatter.string(from: week.start)) \u{2013} \(formatter.string(from: last))"
    }

    // MARK: Streak

    var streakChipText: String { "\(streak.current) wk" }

    var streakAccessibility: String {
        let weeks = streak.current == 1 ? "1 week" : "\(streak.current) weeks"
        return "Weekly streak: \(weeks). \(streak.thisWeekDays) of \(streak.goal) workouts this week."
    }
}
