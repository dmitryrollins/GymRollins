import GymCore
import SwiftUI

/// Root screen of the workout flow: pause/clock/finish bar, one row per exercise, add-exercise,
/// and a floating rest capsule while a rest timer is running.
struct WorkoutOverviewView: View {
    @Bindable var session: WorkoutSession
    let finish: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var showAddExercise = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                topBar
                header
                if let lastError = session.lastError {
                    Text(lastError).font(.footnote).foregroundStyle(Theme.destructive)
                }
                ForEach(session.workout.entries) { entry in
                    entryRow(entry)
                }
                addExerciseButton
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) { restCapsule }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }.accessibilityIdentifier("workout.close")
            }
        }
        .sheet(isPresented: $showAddExercise) {
            ExercisePickerView(excluded: Set(session.workout.entries.map(\.exerciseId))) { ids in
                session.addExercises(ids) { env.adHocEntry(exerciseId: $0) }
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                session.togglePause()
            } label: {
                Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
            }
            .glassCircle()
            .accessibilityLabel(session.isPaused ? "Resume" : "Pause")
            .accessibilityIdentifier("workout.pause")

            Spacer(minLength: 4)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 7) {
                    Image(systemName: "timer").font(.subheadline.weight(.semibold)).accessibilityHidden(true)
                    Text(DurationFormatter.clock(session.elapsed(at: env.now())))
                        .font(Theme.display(22))
                        .accessibilityIdentifier("workout.clock")
                }
            }
            .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 4)

            Button(action: finish) { Text("Finish").fixedSize() }
                .buttonStyle(.glassProminent)
                .tint(Theme.primaryFill)
                .accessibilityIdentifier("workout.finish")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 56)
        .glassCapsule(interactive: false)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            DisplayTitle(text: session.workout.name, size: 36)
            Text(subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
    }

    private var subtitle: String {
        let date = session.workout.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let count = session.workout.entries.count
        return "\(date) \u{00B7} \(count) exercise\(count == 1 ? "" : "s")"
    }

    // MARK: Entry rows

    // The whole-row identifier ("workout.entry.<id>") must NOT sit on an ancestor of the counter
    // text: on this SDK, a container's accessibilityIdentifier overrides its identified
    // descendants' own identifiers. So the counter is a same-frame ZStack sibling (tap-through,
    // its own identifier) instead of a child of the tappable NavigationLink.
    private func entryRow(_ entry: WorkoutEntry) -> some View {
        let isCurrent = entry.id == session.currentEntryId
        let done = entry.sets.filter(\.done).count
        let total = entry.sets.count
        let allDone = total > 0 && done == total
        return ZStack(alignment: .trailing) {
            NavigationLink(value: entry.id) {
                HStack(spacing: 12) {
                    ExerciseThumbnail(exercise: env.library.exercise(entry.exerciseId))
                    VStack(alignment: .leading, spacing: 2) {
                        if isCurrent {
                            Text("IN PROGRESS")
                                .font(.caption2.weight(.bold))
                                .kerning(0.8)
                                .foregroundStyle(Theme.accent)
                        }
                        Text(exerciseName(entry.exerciseId))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(summary(for: entry))
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 60)
                }
                .padding(10)
                .background(isCurrent ? Theme.accent.opacity(0.08) : Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(isCurrent ? Theme.accent : .clear, lineWidth: 1.5)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("workout.entry.\(entry.exerciseId)")

            HStack(spacing: 6) {
                if allDone {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.black))
                        .frame(width: 22, height: 22)
                        .background(Theme.successFill, in: .rect(cornerRadius: 6))
                        .foregroundStyle(Theme.success)
                }
                Text("\(done)/\(total)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(allDone ? Theme.success : (isCurrent ? Theme.accent : Theme.textTertiary))
            }
            .padding(.trailing, 20)
            .allowsHitTesting(false)
            .accessibilityIdentifier("workout.entry.\(entry.exerciseId).count")
        }
    }

    private func exerciseName(_ id: String) -> String {
        DisplayName.of(env.library.exercise(id)?.name ?? id)
    }

    private func summary(for entry: WorkoutEntry) -> String {
        let working = entry.sets.filter { !$0.warmup }
        guard let first = working.first else { return "\(entry.sets.count) sets" }
        return "\(working.count) \u{00D7} \(first.reps) \u{00B7} " +
            WeightFormatter.format(kg: first.weightKg, unit: env.profile.unit)
    }

    private var addExerciseButton: some View {
        HStack {
            Spacer()
            GlassPillButton(title: "+ Add exercise", identifier: "workout.addExercise") { showAddExercise = true }
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: Rest capsule

    @ViewBuilder
    private var restCapsule: some View {
        if session.rest != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let rest = session.activeRest(at: env.now()) {
                    restButton(rest)
                }
            }
        }
    }

    private func restButton(_ rest: RestTimer) -> some View {
        Button {
            session.skipRest()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "timer").foregroundStyle(Theme.accent)
                Text("Rest \(rest.label(at: env.now()))").font(.subheadline.weight(.bold))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 46)
        .glassCapsule()
        .accessibilityIdentifier("workout.rest")
        .padding(.bottom, 26)
    }
}
