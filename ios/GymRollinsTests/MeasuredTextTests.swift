import Foundation
import GymCore
import GymHealth
import Testing
import UIKit
@testable import GymRollins

/// Plan 40, spec §4: the words and metrics of a GymRollins workout's detail in Apple Fitness' look (the header, Workout
/// Details and its footnote, Strength), each with what VoiceOver says. Sat 19 Sep 2026, 18:00–18:58:20 UTC.
@Suite struct MeasuredTextTests {
    private let start = ISO8601DateFormatter().date(from: "2026-09-19T18:00:00Z")!
    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!

    private func summary(_ source: MeasuredSummary.Source, time: TimeInterval = 3_500, active: Double? = 412,
                         total: Double? = 489, estimate: Int? = nil, avg: Int? = 128, max: Int? = 162,
                         effort: Effort? = nil) -> MeasuredSummary {
        MeasuredSummary(source: source, workoutTime: time, activeKcal: active, totalKcal: total,
                        estimatedKcal: estimate, avgHr: avg, maxHr: max, heartRate: [], postWorkout: [],
                        lastPostHr: nil, postHr: nil, effort: effort)
    }

    private var estimateOnly: MeasuredSummary {
        summary(.estimate, active: nil, total: nil, estimate: 277, avg: nil, max: nil)
    }

    private func workout(sets: Int = 3, kg: Double = 59) -> Workout {
        Workout(startedAt: start, endedAt: start.addingTimeInterval(3_500), name: "Push + Biceps",
                entries: [WorkoutEntry(exerciseId: "0025", sets: (0..<sets).map { _ in
                    WorkoutSet(weightKg: kg, reps: 10, done: true)
                } + [WorkoutSet(weightKg: 20, reps: 10, done: true, warmup: true)])])
    }

    // MARK: Header

    @Test func theHeadlineIsTheWorkoutTimeInGreenYellow() {
        let headline = MeasuredText.headline(summary(.watch))
        #expect(headline.value == "58:20" && headline.unit == nil && headline.tint == .workout)
        #expect(headline.spoken == "58 minutes 20 seconds")
    }

    /// The day's spelling follows the language's data ("Sep" or "Sept"), so only its parts are checked; the times are
    /// 24-hour in en_GB.
    @Test func theDateLineHasTheDayAndTimes() {
        let text = MeasuredText.dateAndTimes(start: start, end: start.addingTimeInterval(3_500), locale: gb,
                                             timeZone: utc)
        #expect(text.hasPrefix("Sat") && text.contains("19") && text.contains("2026"), "\(text)")
        #expect(text.hasSuffix(", 18:00\u{2013}18:58"), "\(text)")
    }

    @Test func whatRecordedIt() {
        #expect(MeasuredText.recordedBy(.watch, loggedHere: true) == RecordedBy(text: "Apple Watch", symbol: "applewatch"))
        #expect(MeasuredText.recordedBy(.attached(sourceName: "Strava"), loggedHere: true)
            == RecordedBy(text: "Strava", symbol: "heart.text.square"))
        #expect(MeasuredText.recordedBy(.estimate, loggedHere: true) == RecordedBy(text: "iPhone", symbol: "iphone"))
        #expect(MeasuredText.recordedBy(.estimate, loggedHere: false) == nil, "an import or an agent's workout")
    }

    // MARK: Workout Details

    @Test func theWatchsCopyFillsTheGridInFitnessOrder() {
        #expect(MeasuredText.details(summary(.watch), usedDefaultBodyWeight: false) == [
            MetricReading(key: "workoutTime", label: "Workout Time", value: "0:58:20", unit: nil,
                          spoken: "58 minutes 20 seconds", tint: .time),
            MetricReading(key: "activeKcal", label: "Active Calories", value: "412", unit: "KCAL",
                          spoken: "412 kilocalories", tint: .calories),
            MetricReading(key: "totalKcal", label: "Total Calories", value: "489", unit: "KCAL",
                          spoken: "489 kilocalories", tint: .calories),
            MetricReading(key: "avgHeartRate", label: "Avg. Heart Rate", value: "128", unit: "BPM",
                          spoken: "128 beats per minute", tint: .heartRate),
            MetricReading(key: "maxHeartRate", label: "Max Heart Rate", value: "162", unit: "BPM",
                          spoken: "162 beats per minute", tint: .heartRate),
        ])
    }

    @Test func anAttachedRecordingWithoutRestingEnergyHasNoTotal() {
        let readings = MeasuredText.details(summary(.attached(sourceName: "Apple Watch"), time: 3_180, total: nil),
                                            usedDefaultBodyWeight: false)
        #expect(readings.map(\.key) == ["workoutTime", "activeKcal", "avgHeartRate", "maxHeartRate"])
        #expect(readings.first?.value == "0:53:00")
    }

    @Test func nothingMeasuredShowsTheEstimateAndNoTotal() {
        #expect(MeasuredText.details(estimateOnly, usedDefaultBodyWeight: false, locale: gb) == [
            MetricReading(key: "workoutTime", label: "Workout Time", value: "0:58:20", unit: nil,
                          spoken: "58 minutes 20 seconds", tint: .time),
            MetricReading(key: "kcal", label: "Calories (estimated)", value: "\u{2248} 277", unit: "KCAL",
                          spoken: "about 277 kilocalories", tint: .calories),
        ])
        #expect(MeasuredText.details(estimateOnly, usedDefaultBodyWeight: true, locale: gb)[1].label
            == "Calories (estimated, 70 kg)")
    }

    @Test func heartRateAloneStillShows() {
        let readings = MeasuredText.details(summary(.estimate, active: nil, total: nil, estimate: 277, avg: 115, max: 120),
                                            usedDefaultBodyWeight: false)
        #expect(readings.map(\.key) == ["workoutTime", "kcal", "avgHeartRate", "maxHeartRate"])
    }

    @Test func theFootnoteSaysWhatMeasuredItAndWhetherHealthHasIt() {
        #expect(MeasuredText.measuredBy(.watch) == "Measured by Apple Watch")
        #expect(MeasuredText.measuredBy(.attached(sourceName: "Apple Watch")) == "Measured by Apple Watch")
        #expect(MeasuredText.measuredBy(.estimate) == "Estimated from your sets and body weight")
        #expect(MeasuredText.healthSave(.notEnabled) == nil)
        #expect(MeasuredText.healthSave(.notEligible) == nil)
        #expect(MeasuredText.healthSave(.pending)?.text == "Saving to Apple Health\u{2026}")
        #expect(MeasuredText.healthSave(.saved)?.text == "Saved to Apple Health")
        #expect(MeasuredText.healthSave(.failed)?.text == "Couldn't save to Apple Health")
    }

    // MARK: Strength

    @Test func strengthIsTheAppsOwnNumbers() {
        #expect(MeasuredText.strength(workout(), records: 2, locale: gb) == [
            MetricReading(key: "exercises", label: "Exercises", value: "1", unit: nil, spoken: "1 exercise",
                          tint: .primary),
            MetricReading(key: "sets", label: "Sets", value: "3", unit: nil, spoken: "3 sets", tint: .primary),
            MetricReading(key: "volume", label: "Volume", value: "1.8", unit: "T", spoken: "1.8 tonnes", tint: .primary),
            MetricReading(key: "records", label: "Records", value: "2", unit: nil, spoken: "2 records", tint: .record),
        ])
        #expect(MeasuredText.strength(workout(), records: 0, locale: gb).last?.tint == .primary,
                "amber only for a record")
    }

    @Test func volumeUnderATonneIsInKilograms() {
        let volume = MeasuredText.volume(885, locale: gb)
        #expect(volume.value == "885" && volume.unit == "KG" && volume.spoken == "885 kilograms")
    }

    @Test func tonnesUseTheLanguagesDecimalSeparator() {
        let volume = MeasuredText.volume(1_770, locale: Locale(identifier: "de_DE"))
        #expect(volume.value == "1,8" && volume.spoken == "1,8 tonnes")
    }

    // MARK: Sets

    @Test func aWorkingSetSaysItsNumberRepsWeightAndRepsLeft() {
        let set = WorkoutSet(weightKg: UnitConverter.toKg(130, from: .lb), weightLb: 130, reps: 10, done: true, rir: 2)
        #expect(MeasuredText.spokenSet(set, position: 1, mode: .reps, unit: .lb)
            == "Set 1, 10 reps, 130 pounds, 2 reps left")
        #expect(MeasuredText.spokenSet(set, position: 3, mode: .reps, unit: .kg)
            == "Set 3, 10 reps, 59 kilograms, 2 reps left")
    }

    @Test func aWarmUpSaysWarmUpAndIsNeverRated() {
        let set = WorkoutSet(weightKg: UnitConverter.toKg(44, from: .lb), weightLb: 44, reps: 8, done: true,
                             warmup: true, rir: 1)
        #expect(MeasuredText.spokenSet(set, position: 1, mode: .reps, unit: .lb) == "Warm-up, 8 reps, 44 pounds")
    }

    // MARK: Effort

    @Test func effortIsANumberAndItsWord() throws {
        #expect(MeasuredText.effort(try #require(Effort(score: 6, estimated: false)), locale: gb) == "6 Moderate")
        #expect(MeasuredText.effort(try #require(Effort(score: 5, estimated: true)), locale: gb)
            == "5 Moderate \u{00B7} Estimated")
        #expect(MeasuredText.spokenEffort(try #require(Effort(score: 9, estimated: false)), locale: gb)
            == "9 out of 10, All Out")
        #expect(MeasuredText.spokenEffort(try #require(Effort(score: 2, estimated: true)), locale: gb)
            == "2 out of 10, Easy, estimated")
        #expect(MeasuredText.spokenScore(10, locale: gb) == "10, All Out")
    }

    @Test func theScaleHasApplesFourWords() {
        #expect((1...10).map { MeasuredText.effortWord($0) ?? "" } == [
            "Easy", "Easy", "Easy", "Moderate", "Moderate", "Moderate", "Hard", "Hard", "All Out", "All Out",
        ])
        #expect(MeasuredText.effortWord(0) == nil && MeasuredText.effortWord(11) == nil)
        #expect(MeasuredText.effortKey(locale: gb)
            == "1\u{2013}3 Easy \u{00B7} 4\u{2013}6 Moderate \u{00B7} 7\u{2013}8 Hard \u{00B7} 9\u{2013}10 All Out")
        #expect(MeasuredText.effortNotInHealth == "Couldn't save to Apple Health")
    }

    // MARK: Heart rate charts

    private func readings(_ bpm: [Double], at seconds: [TimeInterval], after base: Date) -> [HeartRateReading] {
        zip(seconds, bpm).map { HeartRateReading(date: base.addingTimeInterval($0), bpm: $1) }
    }

    @Test func theHeartRateChartHasThreeTimesItsAverageAndMaximum() {
        let bpm: [Double] = [110, 118, 124, 131, 136, 162, 140, 129, 122, 118, 126, 120]
        let data = HeartRateChartData.workout(readings(bpm, at: (0..<12).map { 120 + Double($0) * 300 }, after: start),
                                              start: start, end: start.addingTimeInterval(3_500))
        #expect(MeasuredText.tickLabels(data, postWorkout: false, locale: gb, timeZone: utc) == ["18:00", "18:29", "18:58"])
        #expect(MeasuredText.averageCaption(data, locale: gb) == "128 BPM AVG")
        #expect(MeasuredText.maximumLabel(data, locale: gb) == "162")
        #expect(MeasuredText.chartSummary(data, locale: gb, timeZone: utc)
            == "Heart rate 18:00 to 18:58: average 128, maximum 162")
    }

    @Test func thePostWorkoutChartIsTheThreeMinutesAfter() {
        let end = start.addingTimeInterval(3_500)
        let data = HeartRateChartData.postWorkout(readings([141, 132, 124], at: [30, 90, 170], after: end), end: end)
        #expect(MeasuredText.tickLabels(data, postWorkout: true, locale: gb, timeZone: utc) == ["18:58", "1 MIN", "2 MIN"])
        #expect(MeasuredText.lastReadingCaption(124, locale: gb) == "124 BPM")
        #expect(MeasuredText.postChartSummary(data, last: 124, locale: gb, timeZone: utc)
            == "Heart rate after the workout, 18:58 to 19:01: last reading 124")
    }

    @Test func aChartWithoutReadingsSaysSo() {
        let data = HeartRateChartData.workout([], start: start, end: start.addingTimeInterval(3_500))
        #expect(MeasuredText.averageCaption(data, locale: gb) == nil)
        #expect(MeasuredText.maximumLabel(data, locale: gb) == nil)
        #expect(MeasuredText.chartSummary(data, locale: gb, timeZone: utc) == "Heart rate 18:00 to 18:58: no readings")
    }

    /// What the audio graph says for a point: how far into the chart, and the reading.
    @Test func theAudioGraphSpeaksMinutesInAndBeats() {
        #expect(MeasuredText.spokenMinutesIn(1_750, locale: gb) == "29 minutes in")
        #expect(MeasuredText.spokenMinutesIn(90, locale: gb) == "1 minute in")
        #expect(MeasuredText.spokenBpm(127.6, locale: gb) == "128 beats per minute")
    }

    @Test func everySymbolExists() {
        for name in ["applewatch", "iphone", "heart.text.square", "info.circle", "square.and.arrow.up", "ellipsis",
                     "chevron.left", "figure.strengthtraining.traditional", "heart", "heart.fill",
                     "exclamationmark.triangle", "plus.circle", "chevron.right"] {
            #expect(UIImage(systemName: name) != nil, "\(name)")
        }
    }
}
