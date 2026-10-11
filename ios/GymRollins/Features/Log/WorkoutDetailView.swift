import GymCore
import SwiftUI

/// Workout detail, pushed from a `WorkoutCard`: glass back + "•••" menu (Edit / Delete), stat
/// tiles, a card per exercise with its set rows (warm-ups labelled "W"), an edit mode that turns
/// each row into its exercise mode's fields (reps/weight, seconds/weight, or minutes/distance) plus the
/// "Reps left?" rating for working reps sets,
/// and a share sheet with a plain-text recap.
struct WorkoutDetailView: View {
    let workoutId: UUID
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var workout: Workout?
    @State private var recordCount = 0
    @State private var editing = false
    @State private var drafts: [SetField: String] = [:]
    /// Edited "Reps left?" ratings by set id (a nil value clears the rating), applied on Save.
    @State private var effortDrafts: [UUID: Double?] = [:]
    @State private var showMenu = false

    private var unit: WeightUnit { env.profile.unit }

    var body: some View {
        Group {
            if let workout {
                scrollContent(workout)
            } else {
                Color.clear
            }
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showMenu) {
            WorkoutOptionsSheet(onEdit: startEditing, onDelete: delete)
        }
        .task(id: workoutId) { load() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
                .glassCircle()
                .accessibilityLabel("Back")
                .accessibilityIdentifier("detail.back")
            Spacer()
            if editing {
                Button("Cancel") { cancelEditing() }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("detail.cancel")
                Button("Save", action: save)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.primaryFill)
                    .accessibilityIdentifier("detail.save")
            } else {
                Button { showMenu = true } label: { Image(systemName: "ellipsis") }
                    .glassCircle()
                    .accessibilityLabel("Edit or delete workout")
                    .accessibilityIdentifier("detail.menu")
            }
        }
    }

    // MARK: Content

    private func scrollContent(_ workout: Workout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                topBar
                titleBlock(workout)
                statGrid(workout)
                CalorieCard(estimate: env.calories.estimate(workout), healthStatus: env.health.exportStatus(for: workout),
                            prefix: "detail")
                exerciseList(workout)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .bottom) {
            if !editing { shareBar(workout) }
        }
    }

    private func titleBlock(_ workout: Workout) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workout.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
            Text(workout.name).font(Theme.display(34)).foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: Stats

    private func statGrid(_ workout: Workout) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            stat(label: "Duration", value: DurationFormatter.clock(durationSeconds(workout)), identifier: "detail.duration")
            stat(label: "Exercises", value: "\(workout.entries.count)", identifier: "detail.exercises")
            stat(label: "Volume", value: volumeText(workout), identifier: "detail.volume")
            stat(label: "Records", value: "\(recordCount)", identifier: "detail.records",
                tint: recordCount > 0 ? Theme.record : Theme.textPrimary)
        }
    }

    private func stat(label: String, value: String, identifier: String, tint: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.display(22)).foregroundStyle(tint).accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.card, in: .rect(cornerRadius: 14))
    }

    private func durationSeconds(_ workout: Workout) -> TimeInterval {
        max(0, (workout.endedAt ?? workout.startedAt).timeIntervalSince(workout.startedAt) - workout.pausedSeconds)
    }

    private func volumeText(_ workout: Workout) -> String {
        let kg = WorkoutMetrics.volumeKg(workout)
        return kg >= 1_000 ? String(format: "%.1f t", kg / 1_000) : "\(WeightFormatter.number(kg)) kg"
    }

    // MARK: Exercises

    private func exerciseList(_ workout: Workout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(workout.entries.enumerated()), id: \.element.id) { entryIndex, entry in
                exerciseCard(entry, entryIndex: entryIndex)
            }
        }
    }

    private func exerciseCard(_ entry: WorkoutEntry, entryIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(exerciseName(entry.exerciseId)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            ForEach(Array(entry.sets.enumerated()), id: \.element.id) { setIndex, set in
                setRow(set, entry: entry, entryIndex: entryIndex, setIndex: setIndex)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private func setRow(_ set: WorkoutSet, entry: WorkoutEntry, entryIndex: Int, setIndex: Int) -> some View {
        let label = setLabel(set, entry: entry)
        let mode = entryMode(entry)
        if editing {
            editRow(set, mode: mode, label: label, entryIndex: entryIndex, setIndex: setIndex)
            if SetEffort.canRate(set, mode: mode) {
                SetEffortRow(rir: effortDrafts[set.id] ?? set.rir,
                             identifierPrefix: "detail.set.\(entryIndex).\(setIndex).effort") { choice in
                    effortDrafts[set.id] = SetEffort.toggled(effortDrafts[set.id] ?? set.rir, tapping: choice)
                }
                .padding(.leading, 24)
            }
        } else {
            Text("\(label) \(setSummaryText(set, mode: mode))\(effortSuffix(set, mode: mode))")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func editRow(_ set: WorkoutSet, mode: ExerciseMode, label: String, entryIndex: Int, setIndex: Int) -> some View {
        let fields = SetFieldFormat.fields(for: mode, setId: set.id)
        return HStack(spacing: 8) {
            Text(label).font(.caption.weight(.bold)).foregroundStyle(Theme.textTertiary).frame(width: 16)
            fieldBox(fields[0], set: set, entryIndex: entryIndex, setIndex: setIndex)
            Text(mode == .reps ? "\u{00D7}" : "\u{00B7}").font(.footnote).foregroundStyle(Theme.textSecondary)
            fieldBox(fields[1], set: set, entryIndex: entryIndex, setIndex: setIndex)
            Text(trailingUnit(mode)).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private func fieldBox(_ field: SetField, set: WorkoutSet, entryIndex: Int, setIndex: Int) -> some View {
        TextField(SetFieldFormat.label(field, warmup: set.warmup, unit: unit), text: draftBinding(field, set: set))
            .keyboardType(SetFieldFormat.isDecimal(field) ? .decimalPad : .numberPad)
            .textFieldStyle(.roundedBorder)
            .frame(width: field.identifierSuffix == "reps" ? 56 : 64)
            .accessibilityIdentifier("detail.set.\(entryIndex).\(setIndex).\(field.identifierSuffix)")
    }

    private func trailingUnit(_ mode: ExerciseMode) -> String {
        mode == .cardio ? SetFieldFormat.distanceUnit(unit) : unit.rawValue
    }

    /// Individual set's non-editing summary, formatted for `mode`.
    private func setSummaryText(_ set: WorkoutSet, mode: ExerciseMode) -> String {
        switch mode {
        case .reps:
            return "\(set.reps) \u{00D7} \(WeightFormatter.format(kg: set.weightKg, unit: unit, includeSecondary: false))"
        case .time:
            return DurationFormatter.clock(TimeInterval(set.sec ?? 0))
        case .cardio:
            let minutes = SetFieldFormat.display(.minutes(set.id), set: set, unit: unit)
            let distance = SetFieldFormat.display(.distance(set.id), set: set, unit: unit)
            guard !distance.isEmpty else { return "\(minutes) min" }
            return "\(minutes) min \u{00B7} \(distance) \(SetFieldFormat.distanceUnit(unit))"
        }
    }

    /// " · 2 left" for a rated working set.
    private func effortSuffix(_ set: WorkoutSet, mode: ExerciseMode) -> String {
        guard SetEffort.canRate(set, mode: mode), let choice = SetEffort.choice(for: set.rir) else { return "" }
        return " \u{00B7} \(SetEffortText.title(choice)) left"
    }

    /// "W" for warm-ups; otherwise the 1-based position among working sets up to and including this one.
    private func setLabel(_ set: WorkoutSet, entry: WorkoutEntry) -> String {
        guard !set.warmup else { return "W" }
        let position = entry.sets.prefix(while: { $0.id != set.id }).filter { !$0.warmup }.count + 1
        return "\(position)"
    }

    private func entryMode(_ entry: WorkoutEntry) -> ExerciseMode {
        SetFieldFormat.mode(exercise: env.library.exercise(entry.exerciseId), sets: entry.sets)
    }

    private func draftBinding(_ field: SetField, set: WorkoutSet) -> Binding<String> {
        Binding(get: { drafts[field] ?? SetFieldFormat.display(field, set: set, unit: unit) },
                set: { drafts[field] = $0 })
    }

    private func exerciseName(_ id: String) -> String {
        DisplayName.of(env.library.exercise(id)?.name ?? id)
    }

    // MARK: Share

    private func shareBar(_ workout: Workout) -> some View {
        ShareLink(item: shareText(workout)) {
            Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("detail.share")
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 8)
    }

    private func shareText(_ workout: Workout) -> String {
        let date = workout.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let minutes = Int(durationSeconds(workout) / 60)
        var lines = ["\(workout.name) \u{2014} \(date), \(minutes) min"]
        for entry in workout.entries {
            let summary = WorkoutText.setsSummary(entry, unit: unit, mode: entryMode(entry))
            guard !summary.isEmpty else { continue }
            lines.append("\(exerciseName(entry.exerciseId)) \(summary)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Data

    private func load() {
        workout = try? env.workouts.workout(workoutId)
        recordCount = (try? env.workouts.records(for: workoutId).count) ?? 0
    }

    private func startEditing() {
        (drafts, effortDrafts) = ([:], [:])
        editing = true
    }

    private func cancelEditing() {
        (drafts, effortDrafts) = ([:], [:])
        editing = false
    }

    private func save() {
        guard var updated = workout else { return }
        for entry in updated.entries {
            let mode = entryMode(entry)
            for set in entry.sets {
                if let rir = effortDrafts[set.id] {
                    updated = updated.updatingSet(entryId: entry.id, setId: set.id) { $0.with(rir: rir) }
                }
                for field in SetFieldFormat.fields(for: mode, setId: set.id) {
                    guard let text = drafts[field] else { continue }
                    updated = updated.updatingSet(entryId: entry.id, setId: set.id) { current in
                        SetFieldFormat.applying(text, to: field, set: current, unit: unit) ?? current
                    }
                }
            }
        }
        do {
            try env.workouts.save(updated)
            env.dataChanged()
            workout = updated
            (drafts, effortDrafts) = ([:], [:])
            editing = false
        } catch {
            AppEnvironment.log.error("Save workout failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func delete() {
        do {
            try env.workouts.delete(workoutId)
            env.dataChanged()
            dismiss()
        } catch {
            AppEnvironment.log.error("Delete workout failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The "•••" glass menu's sheet: Edit / Delete workout (with its own delete confirmation).
private struct WorkoutOptionsSheet: View {
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 40, height: 5)
            row(title: "Edit", systemImage: "pencil", identifier: "detail.edit", destructive: false) {
                dismiss()
                onEdit()
            }
            row(title: "Delete workout", systemImage: "trash", identifier: "detail.delete", destructive: true) {
                showDeleteConfirm = true
            }
        }
        .padding(20)
        .presentationDetents([.height(190)])
        .confirmationDialog("Delete this workout? This can't be undone.", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                dismiss()
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(title: String, systemImage: String, identifier: String, destructive: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(destructive ? Theme.destructive : Theme.textPrimary)
        }
        .padding(12)
        .background(Theme.card, in: .rect(cornerRadius: 14))
        .accessibilityIdentifier(identifier)
    }
}
