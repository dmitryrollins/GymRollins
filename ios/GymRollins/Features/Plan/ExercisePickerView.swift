import GymCore
import SwiftUI

struct ExercisePickerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let excluded: Set<String>
    /// Single-select mode (e.g. onboarding's import matching): tapping a row resolves and dismisses immediately,
    /// with no multi-select "Add" toolbar button.
    var singleSelect = false
    /// Hide "Don't recommend again" exercises from the unsearched list (false where any exercise must be pickable,
    /// e.g. matching an imported exercise name; they are then only listed last).
    var hidesNever = true
    /// At most this many can be picked (multi-select), e.g. the room left in a workout (`Workout.entriesLeft`);
    /// `limitNote` says why once that many are picked.
    var maxSelected = Int.max
    var limitNote: String?
    let onAdd: ([String]) -> Void
    @State private var query = ""
    @State private var selected: [String] = []

    var body: some View {
        NavigationStack {
            List(ExerciseSuggestions.picker(library: env.library, query: query, excluded: excluded,
                                            preferences: env.exercisePreferences, hidesNever: hidesNever)) { ex in
                Button { tap(ex.id) } label: {
                    HStack {
                        ExerciseThumbnail(exercise: ex, size: 36)
                        Text(DisplayName.of(ex.name)).foregroundStyle(Theme.textPrimary)
                        if !singleSelect {
                            Spacer()
                            Image(systemName: selected.contains(ex.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(ex.id) ? Theme.success : Theme.textTertiary)
                        }
                    }
                }
                .disabled(isFull && !selected.contains(ex.id))
                .accessibilityIdentifier("picker.row.\(ex.id)")
            }
            .safeAreaInset(edge: .bottom) {
                if isFull, let limitNote {
                    Text(limitNote).font(.footnote).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity).padding(12).background(.bar)
                        .accessibilityIdentifier("picker.limit")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .navigationTitle("Add Exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if !singleSelect {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selected.count <= 1 ? "Add" : "Add \(selected.count)") { onAdd(selected); dismiss() }
                            .disabled(selected.isEmpty)
                            .accessibilityIdentifier("picker.add")
                    }
                }
            }
        }
    }

    private func tap(_ id: String) {
        if singleSelect { onAdd([id]); dismiss() } else { toggle(id) }
    }

    /// Multi-select with `maxSelected` picked: the other rows wait until one is unpicked.
    private var isFull: Bool { !singleSelect && selected.count >= maxSelected }

    private func toggle(_ id: String) {
        selected = Self.toggling(id, in: selected, limit: maxSelected)
    }

    /// The selection after tapping `id`: unpicked when it was picked, else picked while fewer than `limit` are.
    static func toggling(_ id: String, in selected: [String], limit: Int) -> [String] {
        if selected.contains(id) { return selected.filter { $0 != id } }
        return selected.count < limit ? selected + [id] : selected
    }
}
