import Foundation
import GymCore
import GymData
import SwiftUI
import Testing
@testable import GymRollins

/// Main-thread work behind Today's and Library's taps, with an owner-sized store: 160 finished workouts of 6 exercises
/// × 3 sets (the bench in 100 of them) and 500 outside workouts over two years. Prints `PERF …` lines (median of
/// `runs` after a warm-up) and asserts nothing about time.
///
/// Only runs with `GYM_PERF=1`: `TEST_RUNNER_GYM_PERF=1 scripts/ios-test.sh
/// -only-testing:GymRollinsTests/ResponsivenessTimingTests`. Each test attaches its lines as `timings.txt`
/// (`xcresulttool export attachments --path <xcresult> --output-path <dir>`).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GYM_PERF"] == "1", "set GYM_PERF=1"), .serialized)
struct ResponsivenessTimingTests {
    static let runs = 20
    static let badgeSize: CGFloat = 52 * 0.6 // ExerciseThumbnail's badge on a list row
    static let staple = "0025"

    /// The lines this test prints, attached when it ends.
    private let lines = Lines()

    private final class Lines: @unchecked Sendable {
        var all: [String] = []
    }

    private func report(_ line: String) {
        print(line)
        lines.all.append(line)
    }

    private func attach() {
        Attachment.record(lines.all.joined(separator: "\n"), named: "timings.txt")
    }

    private func median(_ name: String, runs: Int = Self.runs, _ body: () throws -> Void) rethrows {
        try body()
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<runs { samples.append(try clock.measure(body)) }
        report("PERF \(name): \(Self.ms(samples.sorted()[samples.count / 2])) ms (median of \(runs))")
    }

    private static func ms(_ d: Duration) -> String {
        String(format: "%.2f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1_000)
    }

    private func makeEnv() throws -> AppEnvironment {
        try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fakeHealth", "-fixedNow",
                                                             "2026-09-26T09:00:00Z"]))
    }

    /// 160 workouts over the plan's exercises (the bench in 100) and 500 outside workouts.
    private func seedOwnerSizedData(_ env: AppEnvironment) throws -> [String] {
        let push = try #require(try env.routines.all().first { $0.exercises.count >= 6 })
        let others = push.exercises.map(\.exerciseId).filter { $0 != Self.staple }
        let now = env.now()
        for day in 0..<160 {
            let start = now.addingTimeInterval(Double(-(day + 1)) * 86_400 - 3_600 * 8)
            let ids = (day % 8 < 5 ? [Self.staple] : [others[day % others.count]])
                + (0..<5).map { others[(day + $0) % others.count] }
            let entries = ids.enumerated().map { index, id in
                WorkoutEntry(exerciseId: id, sets: (0..<3).map { set in
                    WorkoutSet(weightKg: Double(100 - index * 10 + day % 5), reps: 8 + set % 2, done: true,
                               completedAt: start.addingTimeInterval(Double(index * 3 + set) * 150))
                })
            }
            try env.workouts.save(Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600),
                                          name: "Day \(day)", entries: entries))
        }
        for index in 0..<500 {
            let start = now.addingTimeInterval(-Double(index) * 1.4 * 86_400 - 3_600 * 3)
            let minutes = Double(8 + index % 50)
            _ = try env.activities.add(
                HealthActivity(id: UUID(), kind: index % 3 == 0 ? "running" : "walking", startedAt: start,
                               endedAt: start.addingTimeInterval(minutes * 60), durationS: minutes * 60,
                               sourceName: "Apple Watch", fromWatch: index % 4 != 0),
                editedAt: now)
        }
        env.bumpDataRevision()
        return push.exercises.map(\.exerciseId)
    }

    // MARK: (a) The muscle badge

    /// One badge as SwiftUI asks for it: the silhouette and every muscle group's shape on its side.
    private func badgePaths(_ layout: MuscleBadgeLayout, data: BodyMapData) -> Int {
        let inset = layout.zoom == .whole ? Self.badgeSize * 0.06 : 0
        let rect = CGRect(x: 0, y: 0, width: Self.badgeSize - 2 * inset, height: Self.badgeSize - 2 * inset)
        let box = layout.box(in: data)
        var elements = 0
        BodySilhouetteShape(side: layout.side, box: box, data: data).path(in: rect).forEach { _ in elements += 1 }
        for group in data.groups(on: layout.side) {
            MuscleRegionShape(group: group, side: layout.side, box: box, data: data).path(in: rect)
                .forEach { _ in elements += 1 }
        }
        return elements
    }

    @Test func muscleBadgePaths() throws {
        let env = try makeEnv()
        let layouts = Array(env.library.search(query: "").lazy
            .compactMap { MuscleBadgeLayout(contributions: MuscleTaxonomy.contributions(for: $0)) }
            .prefix(10))
        #expect(layouts.count == 10)
        let one = try #require(layouts.first)
        let url = try #require(Bundle.main.url(forResource: "body-map", withExtension: "json"))
        let json = try Data(contentsOf: url)
        let clock = ContinuousClock()
        report("PERF BodyMapData.load (once per launch): \(Self.ms(try clock.measure { _ = try BodyMapData.load(json) })) ms")
        let fresh = try BodyMapData.load(json)
        let first = clock.measure { for layout in layouts { _ = badgePaths(layout, data: fresh) } }
        report("PERF 10 badges at 31 pt, first time: \(Self.ms(first)) ms")
        median("10 badges at 31 pt") { for layout in layouts { _ = badgePaths(layout, data: fresh) } }
        median("1 badge at 31 pt") { _ = badgePaths(one, data: fresh) }
        // The recovery card's two small maps (104 pt high), and the Body tab's big one.
        median("recovery card maps (front + back, 104 pt)") {
            for side in BodySide.allCases {
                let rect = CGRect(x: 0, y: 0, width: 104 * fresh.aspectRatio(side), height: 104)
                _ = BodySilhouetteShape(side: side, data: fresh).path(in: rect)
                for group in fresh.groups(on: side) { _ = MuscleRegionShape(group: group, side: side, data: fresh).path(in: rect) }
            }
        }
        attach()
    }

    // MARK: (3) Library's list

    @Test func libraryBodyPass() throws {
        let env = try makeEnv()
        let library = env.library
        report("PERF library size: \(library.exercises.count) exercises")
        median("Library body pass as before: results ×3 + bodyParts") {
            for _ in 0..<3 { _ = library.search(query: "", bodyPart: nil) }
            _ = library.bodyParts
        }
        median("library.search(query: \"\")") { _ = library.search(query: "", bodyPart: nil) }
        median("library.search(query: \"press\")") { _ = library.search(query: "press", bodyPart: nil) }
        median("library.bodyParts") { _ = library.bodyParts }
        attach()
    }

    // MARK: (4) Insights and (2)/(c) Today's refresh

    @Test func insightsAndTodayRefresh() throws {
        let env = try makeEnv()
        let items = try seedOwnerSizedData(env)
        median("env.resolvedActivities() (500 outside, 160 workouts)") { _ = env.resolvedActivities() }
        median("env.insights()") { _ = env.insights() }
        try median("history(limit: 5) per plan item (\(items.count) items)") {
            for id in items { _ = try env.workouts.history(exerciseId: id, limit: 5) }
        }
        median("env.recentActivityDays()") { _ = env.recentActivityDays() }
        try median("env.todaysPlan()") { _ = try env.todaysPlan() }
        // What Today did after a sync that brought rows (plan and data revisions bump together): `reload()` and the
        // `dataRevision` handler each read every item's history, and StreakChip and RecoveryCard each compute insights.
        try median("Today refresh after a sync (as before)") {
            _ = try env.todaysPlan()
            for _ in 0..<2 {
                for id in items { _ = try env.workouts.history(exerciseId: id, limit: 5) }
                _ = env.recentActivityDays()
            }
            _ = env.insights()
            _ = env.insights()
        }
        attach()
    }
}
