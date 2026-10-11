import GymCore
import SwiftUI

/// What the import screen tells the owner about each source: how to get the CSV out of that app.
enum ImportSourceHelp {
    /// Chip title; nil = auto-detect.
    static func title(for source: ImportSource?) -> String {
        source?.displayName ?? "Auto-detect"
    }

    static func text(for source: ImportSource?) -> String {
        switch source {
        case nil:
            "Pick the app, or let GymRollins recognize a Fitbod, Strong, Hevy or FitNotes export from its header."
        case .fitbod?:
            "In Fitbod: Settings \u{2192} Export workout data, then save the CSV to Files."
        case .strong?:
            "In Strong: Settings \u{2192} Export Strong Data (Android: Settings \u{2192} Export Data), then save the CSV "
                + "to Files."
        case .hevy?:
            "In Hevy: Profile \u{2192} Settings \u{2192} Export & Import Data \u{2192} Export Workouts, then save the CSV "
                + "to Files."
        case .fitNotes?:
            "In FitNotes: Settings \u{2192} Data \u{2192} Spreadsheet Export, then save the CSV to Files."
        }
    }

    /// (export column(s), destination, ignored) for the column-mapping card.
    static func mapping(for source: ImportSource) -> [(String, String, Bool)] {
        switch source {
        case .fitbod:
            [("Date", "\u{2192} date", false), ("Exercise", "\u{2192} exercise", false), ("Reps", "\u{2192} reps", false),
             ("Weight(kg)", "\u{2192} weight", false), ("isWarmup", "\u{2192} warm-up flag", false),
             ("Duration(s) \u{00B7} Distance(m)", "\u{2192} cardio", false), ("Note", "\u{2192} note", false),
             ("multiplier", "\u{2192} volume (dumbbell pairs)", false),
             ("Incline \u{00B7} Resistance", "\u{2192} ignored", true)]
        case .strong:
            [("Date \u{00B7} Workout Name \u{00B7} Duration", "\u{2192} workout", false),
             ("Exercise Name", "\u{2192} exercise", false), ("Set Order", "\u{2192} warm-up (W) / set", false),
             ("Weight \u{00B7} Reps \u{00B7} RPE", "\u{2192} set", false), ("Seconds \u{00B7} Distance", "\u{2192} cardio", false),
             ("Notes \u{00B7} Workout Notes", "\u{2192} notes", false), ("Rest Timer rows", "\u{2192} ignored", true)]
        case .hevy:
            [("title \u{00B7} start_time \u{00B7} end_time", "\u{2192} workout", false),
             ("exercise_title", "\u{2192} exercise", false), ("set_type", "\u{2192} warm-up flag", false),
             ("weight \u{00B7} reps \u{00B7} rpe", "\u{2192} set", false), ("duration_seconds \u{00B7} distance", "\u{2192} cardio", false),
             ("superset_id", "\u{2192} superset", false), ("description \u{00B7} exercise_notes", "\u{2192} notes", false),
             ("set_index", "\u{2192} ignored", true)]
        case .fitNotes:
            [("Date", "\u{2192} workout (one per day)", false), ("Exercise", "\u{2192} exercise", false),
             ("Weight \u{00B7} Reps", "\u{2192} set", false), ("Time \u{00B7} Distance", "\u{2192} cardio", false),
             ("Notes", "\u{2192} note", false), ("Category \u{00B7} Kind", "\u{2192} ignored", true)]
        }
    }

    /// User-facing message for a file the chosen importer rejected.
    static func message(for error: WorkoutImportError, selected: ImportSource?) -> String {
        switch error {
        case .emptyFile:
            return "That file is empty."
        case .unrecognizedHeader:
            guard let selected else {
                return "Couldn't recognize this file. Supported: Fitbod, Strong, Hevy and FitNotes CSV exports."
            }
            let columns = WorkoutImporters.importer(for: selected).expectedHeader.joined(separator: ", ")
            return "This doesn't look like a \(selected.displayName) export. Expected columns: \(columns)"
        case .sourceMismatch(let selected, let detected):
            return "This looks like a \(detected.displayName) export, not \(selected.displayName). "
                + "Pick \(detected.displayName) or Auto-detect."
        }
    }
}

/// Chip row choosing the export's app (nil = auto-detect) with one line of export help underneath.
struct ImportSourcePicker: View {
    @Binding var selection: ImportSource?
    var disabled = false

    private static let options: [ImportSource?] = [nil] + ImportSource.allCases.map(Optional.some)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "Exported from")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.options, id: \.self) { option in chip(option) }
                }
                .padding(.vertical, 2)
            }
            Text(ImportSourceHelp.text(for: selection))
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("import.source.help")
        }
    }

    private func chip(_ option: ImportSource?) -> some View {
        let selected = selection == option
        return Button { selection = option } label: {
            Text(ImportSourceHelp.title(for: option)).font(.subheadline.weight(selected ? .bold : .semibold))
                .foregroundStyle(selected ? Theme.background : Theme.textPrimary)
        }
        .buttonStyle(HitAreaButtonStyle())
        .glassCapsule(tint: selected ? Theme.textPrimary : nil)
        .disabled(disabled)
        .accessibilityLabel(ImportSourceHelp.title(for: option))
        .accessibilityHint(option == nil ? "Recognize the app from the file" : "Import a \(option?.displayName ?? "") export")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("import.source.\(option?.rawValue ?? "auto")")
    }
}
