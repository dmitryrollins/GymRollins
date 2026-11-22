import GymCore
import GymData
import SwiftUI

/// "Exercises" on the workout detail: a solid card per exercise with its sets (warm-ups labelled "W", " · 2 left" for a
/// rated working set). In edit mode each set becomes its exercise mode's fields (reps/weight, seconds/weight or
/// minutes/distance) and a working reps set gets the "Reps left?" chips; the drafts are the detail's, applied on Save.
struct WorkoutExerciseList: View {
    let workout: Workout
    let editing: Bool
    @Binding var drafts: [SetField: String]
    /// Edited "Reps left?" ratings by set id (a nil value clears the rating).
    @Binding var effortDrafts: [UUID: Double?]
    @Environment(AppEnvironment.self) private var env
    /// The read-only rows' "W" / "1" column, growing with the text size.
    @ScaledMetric(relativeTo: .caption) private var setLabelWidth: CGFloat = 16

    private var unit: WeightUnit { env.profile.unit }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exercises")
                .font(.title3.bold()).foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("detail.exercises.title")
            ForEach(Array(workout.entries.enumerated()), id: \.element.id) { entryIndex, entry in
                exerciseCard(entry, entryIndex: entryIndex)
            }
        }
    }

    /// The entry's mode (reps, time or cardio): the library's exercise, else the sets' shape.
    static func mode(of entry: WorkoutEntry, library: ExerciseLibrary) -> ExerciseMode {
        SetFieldFormat.mode(exercise: library.exercise(entry.exerciseId), sets: entry.sets)
    }

    static func name(of entry: WorkoutEntry, library: ExerciseLibrary) -> String {
        DisplayName.of(library.exercise(entry.exerciseId)?.name ?? entry.exerciseId)
    }

    // MARK: Cards

    private func exerciseCard(_ entry: WorkoutEntry, entryIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The exercise's photo with its muscle badge, as in the workout's overview; the badge hangs below the
            // photo's corner, so the header keeps room under it.
            HStack(spacing: 12) {
                ExerciseThumbnail(exercise: env.library.exercise(entry.exerciseId))
                Text(Self.name(of: entry, library: env.library))
                    .font(.headline).foregroundStyle(Theme.textPrimary)
            }
            .padding(.bottom, 8)
            ForEach(Array(entry.sets.enumerated()), id: \.element.id) { setIndex, set in
                setRow(set, entry: entry, entryIndex: entryIndex, setIndex: setIndex)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }

    @ViewBuilder
    private func setRow(_ set: WorkoutSet, entry: WorkoutEntry, entryIndex: Int, setIndex: Int) -> some View {
        let label = setLabel(set, entry: entry)
        let mode = Self.mode(of: entry, library: env.library)
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
            readRow(set, mode: mode, label: label, entry: entry)
        }
    }

    /// "1  10 × 130 lb · 2 left": the set's label in its own tertiary column, as in edit mode, then its numbers. One
    /// element that VoiceOver reads in words ("Set 1, 10 reps, 130 pounds, 2 reps left").
    private func readRow(_ set: WorkoutSet, mode: ExerciseMode, label: String, entry: WorkoutEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption.weight(.bold)).foregroundStyle(Theme.textTertiary).frame(width: setLabelWidth)
            Text("\(setSummaryText(set, mode: mode))\(effortSuffix(set, mode: mode))")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MeasuredText.spokenSet(set, position: workingPosition(set, entry: entry), mode: mode,
                                                   unit: unit))
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

    // MARK: Set text

    /// Individual set's non-editing summary, formatted for `mode`.
    private func setSummaryText(_ set: WorkoutSet, mode: ExerciseMode) -> String {
        switch mode {
        case .reps:
            let load = WeightFormatter.format(kg: set.weightKg, lb: set.weightLb, unit: unit, includeSecondary: false)
            return "\(set.reps) \u{00D7} \(load)"
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
        return "\(workingPosition(set, entry: entry))"
    }

    private func workingPosition(_ set: WorkoutSet, entry: WorkoutEntry) -> Int {
        entry.sets.prefix(while: { $0.id != set.id }).filter { !$0.warmup }.count + 1
    }

    private func draftBinding(_ field: SetField, set: WorkoutSet) -> Binding<String> {
        Binding(get: { drafts[field] ?? SetFieldFormat.display(field, set: set, unit: unit) },
                set: { drafts[field] = $0 })
    }
}
