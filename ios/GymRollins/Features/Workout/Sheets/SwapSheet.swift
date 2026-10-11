import GymCore
import SwiftUI

/// Replace the current exercise: candidates are library exercises with the same target, then the
/// same body part (excluding the current one), sorted by how often they've been logged and then
/// by name, then by the owner's preferences (`ExerciseSuggestions.swap`). `onPick` applies the choice (the running
/// workout's entry, or today's plan).
struct SwapSheet: View {
    let exerciseId: String
    /// Not offered (e.g. the other exercises of today's plan).
    var excluded: Set<String> = []
    let onPick: (Exercise) -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var currentExercise: Exercise? { env.library.exercise(exerciseId) }

    var body: some View {
        NavigationStack {
            List {
                if let currentExercise {
                    Section {
                        ExerciseRow(exercise: currentExercise, fallbackName: currentExercise.name,
                                   subtitle: DisplayName.of(currentExercise.equipment))
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    ForEach(filteredCandidates) { candidate in
                        Button {
                            onPick(candidate)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ExerciseThumbnail(exercise: candidate, size: 40)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(DisplayName.of(candidate.name)).foregroundStyle(Theme.textPrimary)
                                    Text("\(DisplayName.of(candidate.equipment)) \u{00B7} Logged " +
                                         "\(loggedCounts[candidate.id, default: 0])\u{00D7}")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                            }
                        }
                        .listRowBackground(Theme.card)
                        .accessibilityIdentifier("swap.row.\(candidate.id)")
                    }
                } header: {
                    SectionLabel(text: "Replace with")
                }
            }
            .listRowSeparatorTint(Theme.divider)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $query, prompt: "Search exercises")
            .toolbar {
                ToolbarItem(placement: .principal) { DisplayTitle(text: "Replace Exercise", size: 22) }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("swap.cancel")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var loggedCounts: [String: Int] {
        let recent = (try? env.workouts.recent(limit: 200)) ?? []
        var result: [String: Int] = [:]
        for workout in recent {
            for workoutEntry in workout.entries { result[workoutEntry.exerciseId, default: 0] += 1 }
        }
        return result
    }

    private var filteredCandidates: [Exercise] {
        guard let currentExercise else { return [] }
        return ExerciseSuggestions.swap(current: currentExercise, library: env.library, loggedCounts: loggedCounts,
                                        preferences: env.exercisePreferences, query: query)
            .filter { !excluded.contains($0.id) }
    }
}
