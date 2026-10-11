import GymCore
import GymData
import SwiftUI

/// One row in the Log's "Past workouts" list: date/duration, an amber records badge, the workout
/// name, and a summary of the first two exercises' working sets.
struct WorkoutCard: View {
    let workout: Workout
    let recordCount: Int
    let unit: WeightUnit
    /// Used to resolve each entry's exercise mode (reps/time/cardio) for its summary; a `nil`
    /// exercise (not found) falls back to inferring the mode from the sets' shape.
    var library: ExerciseLibrary?

    var body: some View {
        NavigationLink(value: workout.id) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(dateAndDuration).font(.caption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if recordCount > 0 {
                        Text("\(recordCount) record\(recordCount == 1 ? "" : "s")")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.record)
                    }
                }
                Text(workout.name).font(.headline).foregroundStyle(Theme.textPrimary)
                if !summary.isEmpty {
                    Text(summary).font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("log.workout.\(workout.id.uuidString)")
    }

    private var dateAndDuration: String {
        let date = workout.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let seconds = max(0, (workout.endedAt ?? workout.startedAt).timeIntervalSince(workout.startedAt) - workout.pausedSeconds)
        return "\(date) \u{00B7} \(DurationFormatter.clock(seconds))"
    }

    private var summary: String {
        workout.entries.prefix(2).map { entry in
            let mode = SetFieldFormat.mode(exercise: library?.exercise(entry.exerciseId), sets: entry.sets)
            return WorkoutText.setsSummary(entry, unit: unit, mode: mode)
        }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}
