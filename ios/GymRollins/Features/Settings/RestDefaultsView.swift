import Foundation
import GymCore
import SwiftUI

/// Settings › Default rest: working / warm-up rest, in seconds, validated against `DomainLimits.restSec` (0…900), and
/// the exercises that rest their own time (`ExerciseRestStore`), each cleared with a swipe.
struct RestDefaultsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var restSec = 120
    @State private var warmupRestSec = 60
    @State private var error: String?

    /// The steppers' footer: what an exercise without its own rest rests (`ExerciseRest`).
    static let suggestionNote: String = {
        let bigLift = DurationFormatter.clock(TimeInterval(ExerciseRest.bigLiftSec))
        let isolation = DurationFormatter.clock(TimeInterval(ExerciseRest.isolationSec))
        return "Big barbell lifts rest at least \(bigLift) and single-muscle exercises at most \(isolation), "
            + "unless you set an exercise's own rest."
    }()

    var body: some View {
        let rests = ExerciseRestRow.rows(env.exerciseRests.seconds) {
            DisplayName.of(env.library.exercise($0)?.name ?? $0)
        }
        Form {
            Section {
                Stepper("Working rest: \(DurationFormatter.clock(TimeInterval(restSec)))", value: $restSec,
                        in: DomainLimits.restSec, step: 15)
                    .accessibilityIdentifier("settings.rest.working")
                Stepper("Warm-up rest: \(DurationFormatter.clock(TimeInterval(warmupRestSec)))",
                        value: $warmupRestSec, in: DomainLimits.restSec, step: 15)
                    .accessibilityIdentifier("settings.rest.warmup")
            } footer: {
                Text(Self.suggestionNote)
            }
            if !rests.isEmpty {
                Section("Your exercise rests") {
                    ForEach(rests) { row in
                        HStack {
                            Text(row.name).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(DurationFormatter.clock(TimeInterval(row.seconds))).foregroundStyle(Theme.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.rest.exercise.\(row.id)")
                    }
                    .onDelete { offsets in
                        for index in offsets { env.exerciseRests.set(nil, for: rests[index].id) }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(Theme.destructive) }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Default Rest")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .task {
            restSec = env.profile.restSec
            warmupRestSec = env.profile.warmupRestSec
        }
        .onChange(of: restSec) { _, _ in save() }
        .onChange(of: warmupRestSec) { _, _ in save() }
    }

    private func save() {
        let updated = env.profile.with(restSec: restSec, warmupRestSec: warmupRestSec)
        do {
            try env.profiles.save(updated)
            env.reloadProfile()
            env.planChanged()
            error = nil
        } catch {
            AppEnvironment.log.error("Save rest defaults failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save. Please try again."
        }
    }
}

/// One exercise's own rest, as Settings lists it.
struct ExerciseRestRow: Equatable, Identifiable {
    let id: String
    let name: String
    let seconds: Int

    /// Every stored rest, sorted by display name (`name` gives an exercise id's).
    static func rows(_ seconds: [String: Int], name: (String) -> String) -> [ExerciseRestRow] {
        seconds.map { ExerciseRestRow(id: $0.key, name: name($0.key), seconds: $0.value) }
            .sorted { a, b in
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
    }
}
