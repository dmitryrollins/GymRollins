import GymCore
import SwiftUI

/// Per-exercise overflow menu: notes, add a warm-up set, remove from workout, cancel.
struct ExerciseOptionsSheet: View {
    @Bindable var session: WorkoutSession
    let entryId: UUID
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    private var entry: WorkoutEntry? { session.workout.entries.first { $0.id == entryId } }

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 40, height: 5)
            if let entry {
                Text(DisplayName.of(env.library.exercise(entry.exerciseId)?.name ?? entry.exerciseId).uppercased())
                    .font(.caption.weight(.bold))
                    .kerning(0.6)
                    .foregroundStyle(Theme.textTertiary)
            }
            TextField("Notes", text: $note, axis: .vertical)
                .padding(12)
                .background(Theme.card, in: .rect(cornerRadius: 14))
                .accessibilityIdentifier("options.note")
                .onSubmit(saveNote)

            Button {
                session.addWarmup(entryId: entryId, barKg: env.profile.barKg)
                dismiss()
            } label: {
                Label("Add warm-up set", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(12)
            .background(Theme.card, in: .rect(cornerRadius: 14))
            .accessibilityIdentifier("options.addWarmup")

            Button(role: .destructive) {
                session.removeEntry(entryId)
                dismiss()
            } label: {
                Label("Remove from workout", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Theme.destructive)
            .padding(12)
            .background(Theme.card, in: .rect(cornerRadius: 14))
            .accessibilityIdentifier("options.remove")

            GlassPillButton(title: "Cancel") { saveNote(); dismiss() }
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .presentationDetents([.medium])
        .onAppear { note = entry?.note ?? "" }
        .onDisappear(perform: saveNote)
    }

    private func saveNote() {
        session.setNote(entryId: entryId, note: note)
    }
}
