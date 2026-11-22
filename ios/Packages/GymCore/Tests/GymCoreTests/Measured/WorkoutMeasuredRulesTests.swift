import Foundation
import Testing
@testable import GymCore

/// Plan 40, spec §5.3: what a GymRollins workout shows as measured. The workout is `-seedHistory`'s of Sat 19 Sep
/// (18:00–18:58:20 UTC); the Apple Watch numbers are made up.
@Suite struct WorkoutMeasuredRulesTests {
    private let start = ISO8601DateFormatter().date(from: "2026-09-19T18:00:00Z")!
    private var end: Date { start.addingTimeInterval(3_500) }

    /// A dozen readings inside the workout, 110–162 BPM, mean 128.
    private var readings: [HeartRateReading] {
        [110.0, 118, 122, 126, 130, 162, 135, 128, 124, 120, 131, 130].enumerated().map { index, bpm in
            HeartRateReading(date: start.addingTimeInterval(60 + Double(index) * 290), bpm: bpm)
        }
    }

    private func after(_ seconds: Double, _ bpm: Double) -> HeartRateReading {
        HeartRateReading(date: end.addingTimeInterval(seconds), bpm: bpm)
    }

    private func watch(heartRate: [HeartRateReading]? = nil, post: [HeartRateReading] = [],
                       effort: Effort? = nil) -> WorkoutMeasurements {
        WorkoutMeasurements(recordedBy: .watch, duration: 3_500, activeKcal: 412, totalKcal: 489,
                            heartRate: heartRate ?? readings, postWorkout: post, effort: effort)
    }

    /// The phone exporter's copy, as if it carried numbers: the rules mustn't trust them either.
    private func phone(effort: Effort? = nil, heartRate: [HeartRateReading]? = nil) -> WorkoutMeasurements {
        WorkoutMeasurements(recordedBy: .phone, duration: 3_500, activeKcal: 277, totalKcal: 350,
                            heartRate: heartRate ?? readings, postWorkout: [], effort: effort)
    }

    /// Apple's Workout app recording the same session (plan 39 rule 6 attaches it).
    private var appleWorkout: HealthActivity {
        HealthActivity(id: UUID(), kind: "traditional_strength", startedAt: start.addingTimeInterval(120),
                       endedAt: start.addingTimeInterval(3_300), durationS: 3_180, kcal: 380, totalKcal: 452,
                       avgHr: 125, maxHr: 158, sourceName: "Apple Watch", fromWatch: true)
    }

    private func summary(_ measurements: WorkoutMeasurements?, attached: HealthActivity? = nil,
                         appEffort: Effort? = nil) -> MeasuredSummary {
        WorkoutMeasuredRules.summary(start: start, end: end, appDuration: 3_480, measurements: measurements,
                                     attached: attached, estimateKcal: 277, appEffort: appEffort)
    }

    @Test func theWatchCopyBeatsAnAttachedRecordingAndTheEstimate() {
        let shown = summary(watch(), attached: appleWorkout)
        #expect(shown.source == .watch)
        #expect(shown.workoutTime == 3_500)
        #expect(shown.activeKcal == 412 && shown.totalKcal == 489)
        #expect(shown.estimatedKcal == nil)
        #expect(shown.avgHr == 128 && shown.maxHr == 162)
        #expect(shown.heartRate == readings)
    }

    @Test func anAttachedRecordingBeatsTheEstimate() {
        let shown = summary(nil, attached: appleWorkout)
        #expect(shown.source == .attached(sourceName: "Apple Watch"))
        #expect(shown.workoutTime == 3_180)
        #expect(shown.activeKcal == 380 && shown.totalKcal == 452)
        #expect(shown.estimatedKcal == nil)
        #expect(shown.avgHr == 125 && shown.maxHr == 158, "no readings: the recording's own")
    }

    @Test func aPhoneCopyIsNeverMeasured() {
        let shown = summary(phone())
        #expect(shown.source == .estimate)
        #expect(shown.workoutTime == 3_480, "the app's own time")
        #expect(shown.activeKcal == nil && shown.totalKcal == nil)
        #expect(shown.estimatedKcal == 277)
        #expect(shown.avgHr == 128 && shown.maxHr == 162, "heart rate counts whatever measured the time")
        #expect(summary(phone(), attached: appleWorkout).source == .attached(sourceName: "Apple Watch"))
    }

    @Test func withHealthOffOnlyTheAppsValuesShow() {
        let shown = summary(nil)
        #expect(shown == MeasuredSummary(source: .estimate, workoutTime: 3_480, activeKcal: nil, totalKcal: nil,
                                         estimatedKcal: 277, avgHr: nil, maxHr: nil, heartRate: [], postWorkout: [],
                                         lastPostHr: nil, postHr: nil, effort: nil))
        #expect(shown.snapshot(workoutId: UUID(), at: end) == nil, "nothing to save")
        #expect(summary(WorkoutMeasurements.none) == shown)
    }

    @Test func readingsOutsideTheWorkoutDontCount() {
        let early = HeartRateReading(date: start.addingTimeInterval(-60), bpm: 190)
        let late = after(1, 40)
        let shown = summary(watch(heartRate: readings + [early, late]))
        #expect(shown.heartRate == readings)
        #expect(shown.avgHr == 128 && shown.maxHr == 162)
    }

    @Test func heartRateIsInWholeBeats() {
        let odd = [HeartRateReading(date: start.addingTimeInterval(60), bpm: 127.5),
                   HeartRateReading(date: start.addingTimeInterval(120), bpm: 128.4)]
        let shown = summary(watch(heartRate: odd))
        #expect(shown.avgHr == 128, "127.95")
        #expect(shown.maxHr == 128, "128.4")
    }

    @Test func postWorkoutIsTheThreeMinutesAfterTheEnd() {
        let shown = summary(watch(post: [after(20, 140), after(110, 127), after(170, 119), after(200, 115)]))
        #expect(shown.postWorkout.map(\.bpm) == [140, 127, 119])
        #expect(shown.postHr == 127, "closest to 2 minutes after the end")
        #expect(shown.lastPostHr == 119, "the chart's caption: the last reading")
        let none = summary(watch())
        #expect(none.postWorkout.isEmpty && none.postHr == nil && none.lastPostHr == nil)
    }

    @Test func aRatingInHealthBeatsTheAppsWhichBeatsTheWatchsEstimate() throws {
        let rated = try #require(Effort(score: 8, estimated: false))
        let estimate = try #require(Effort(score: 5, estimated: true))
        let mine = try #require(Effort(score: 6, estimated: false))
        #expect(summary(watch(effort: rated), appEffort: mine).effort == rated)
        #expect(summary(watch(effort: estimate), appEffort: mine).effort == mine)
        #expect(summary(watch(effort: estimate)).effort == estimate)
        #expect(summary(nil, appEffort: mine).effort == mine, "Health off: the app's own")
        #expect(summary(watch()).effort == nil)
    }

    @Test func theSnapshotSavesWhatTheWatchMeasured() throws {
        let id = UUID()
        let mine = try #require(Effort(score: 6, estimated: false))
        let shown = summary(watch(post: [after(30, 135), after(75, 126), after(118, 124)]), appEffort: mine)
        let row = try #require(shown.snapshot(workoutId: id, at: end))
        #expect(row == MeasurementSnapshot(workoutId: id, recordedBy: .watch, durationS: 3_500, activeKcal: 412,
                                           totalKcal: 489, avgHr: 128, maxHr: 162, postHr: 124, effort: 6,
                                           effortEstimated: false, clientUpdatedAt: end))
        #expect(row.isValid)
    }

    @Test func anAttachedRecordingSavesAsAppleWorkoutAndAnEstimateAsNobodys() throws {
        let id = UUID()
        let attached = try #require(summary(nil, attached: appleWorkout).snapshot(workoutId: id, at: end))
        #expect(attached.recordedBy == .appleWorkout)
        #expect(attached.durationS == 3_180 && attached.activeKcal == 380 && attached.totalKcal == 452)

        let heartOnly = try #require(summary(phone()).snapshot(workoutId: id, at: end))
        #expect(heartOnly.recordedBy == nil && heartOnly.durationS == nil)
        #expect(heartOnly.activeKcal == nil && heartOnly.totalKcal == nil)
        #expect(heartOnly.avgHr == 128 && heartOnly.maxHr == 162 && heartOnly.effort == nil)

        let estimate = try #require(Effort(score: 5, estimated: true))
        let effortOnly = try #require(summary(phone(effort: estimate, heartRate: [])).snapshot(workoutId: id, at: end))
        #expect(effortOnly.recordedBy == nil && effortOnly.avgHr == nil)
        #expect(effortOnly.effort == 5 && effortOnly.effortEstimated)
    }

    @Test func aWatchCopyWithoutADurationSavesNoDuration() throws {
        let copy = WorkoutMeasurements(recordedBy: .watch, duration: nil, activeKcal: 412, totalKcal: 489,
                                       heartRate: readings, postWorkout: [], effort: nil)
        let shown = summary(copy)
        #expect(shown.source == .watch)
        #expect(shown.workoutTime == 3_480, "shows the app's time")
        let row = try #require(shown.snapshot(workoutId: UUID(), at: end))
        #expect(row.recordedBy == .watch && row.durationS == nil)
        #expect(row.activeKcal == 412 && row.totalKcal == 489)
    }

    @Test func readingsThatArentRealNumbersAreIgnored() {
        let bad = [HeartRateReading(date: start.addingTimeInterval(30), bpm: .nan),
                   HeartRateReading(date: start.addingTimeInterval(40), bpm: .infinity),
                   HeartRateReading(date: start.addingTimeInterval(50), bpm: 0)]
        let postBad = [after(10, .nan), after(20, 0), after(30, .infinity)]
        let shown = summary(watch(heartRate: bad + readings, post: postBad + [after(110, 127)]))
        #expect(shown.heartRate == readings)
        #expect(shown.avgHr == 128 && shown.maxHr == 162)
        #expect(shown.postWorkout.map(\.bpm) == [127] && shown.postHr == 127 && shown.lastPostHr == 127)
        let reversed = summary(watch(heartRate: readings + bad))
        #expect(reversed.avgHr == 128 && reversed.maxHr == 162)
    }
}
