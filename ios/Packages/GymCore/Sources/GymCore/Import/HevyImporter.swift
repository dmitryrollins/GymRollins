import Foundation

/// Hevy's "Export Workouts" CSV: one row per set,
/// `title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,set_type,
/// weight_kg|weight_lbs,reps,distance_km|distance_miles,duration_seconds,rpe`. The unit is in the column name.
/// Times are local wall-clock (`5 Jan 2026, 18:00`; older/other locales `Jan 5, 2026, 6:00 PM`).
/// `set_type` `warmup` is a warm-up; `normal`, `failure`, `drop_set`/`dropset` and unknown values are working sets.
public enum HevyImporter: WorkoutImporter {
    public static let source = ImportSource.hevy
    public static let expectedHeader = ["title", "start_time", "end_time", "description", "exercise_title",
                                        "superset_id", "exercise_notes", "set_index", "set_type", "weight_kg", "reps",
                                        "distance_km", "duration_seconds", "rpe"]
    private static let required = ["title", "start_time", "exercise_title", "set_type", "reps"]
    private static let dateFormats = ["d MMM yyyy, HH:mm", "MMM d, yyyy, h:mm a", "d MMM yyyy, HH:mm:ss",
                                      "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX"]

    public static func recognizes(header: [String]) -> Bool {
        let keys = ImportTable.keys(header)
        return keys.isSuperset(of: required) && (keys.contains("weight_kg") || keys.contains("weight_lbs"))
    }

    private struct Columns {
        let title, start, end, description, exercise, superset, exerciseNotes, setType, weight, reps: Int?
        let distance, duration, rpe: Int?
        let weightUnit: WeightUnit
        let distanceUnit: DistanceUnit

        /// Header width: every row must have at least this many fields.
        let count: Int

        init(_ t: ImportTable) {
            count = t.header.count
            title = t.column("title"); start = t.column("start_time"); end = t.column("end_time")
            description = t.column("description"); exercise = t.column("exercise_title")
            superset = t.column("superset_id"); exerciseNotes = t.column("exercise_notes")
            setType = t.column("set_type"); reps = t.column("reps"); duration = t.column("duration_seconds")
            rpe = t.column("rpe")
            let kg = t.column("weight_kg")
            weight = kg ?? t.column("weight_lbs")
            weightUnit = kg == nil ? .lb : .kg
            let km = t.column("distance_km")
            let meters = t.column("distance_meters", "distance_m")
            distance = km ?? meters ?? t.column("distance_miles")
            distanceUnit = km != nil ? .kilometers : meters != nil ? .meters : .miles
        }
    }

    public static func parse(_ text: String, options: ImportOptions) throws -> WorkoutImportResult {
        let table = try ImportTable(text)
        guard recognizes(header: table.header) else { throw WorkoutImportError.unrecognizedHeader(table.header) }
        let columns = Columns(table)
        let dates = ImportDateParser(formats: dateFormats, timeZone: options.timeZone)
        let outcomes = table.rows.map { parseRow($0, columns: columns, dates: dates) }
        return ImportAssembler.result(outcomes, source: source) { key, _, _ in ImportID.make([source.rawValue, key]) }
    }

    private static func parseRow(_ record: CSVParser.CSVRecord, columns c: Columns,
                                 dates: ImportDateParser) -> ImportRowOutcome {
        let line = record.line
        if let error = record.missingColumns(expected: c.count) { return .failure(error) }
        let startText = record.value(c.start)
        guard let start = dates.date(startText) else {
            return .failure(ImportRowError(line: line, message: "Unreadable date '\(startText)'"))
        }
        let exercise = record.value(c.exercise)
        guard !exercise.isEmpty else { return .failure(ImportRowError(line: line, message: "Missing exercise name")) }
        var cells = ImportSetCells()
        cells.weight = record.value(c.weight)
        cells.weightUnit = c.weightUnit
        cells.reps = record.value(c.reps)
        cells.seconds = record.value(c.duration)
        cells.distance = record.value(c.distance)
        cells.distanceUnit = c.distanceUnit
        cells.rpe = record.value(c.rpe)
        cells.warmup = record.value(c.setType).lowercased() == "warmup"
        cells.note = record.value(c.exerciseNotes).nonEmpty
        switch cells.build(line: line) {
        case .failure(let error): return .failure(error)
        case .success(nil): return .ignored
        case .success(let set?):
            let title = record.value(c.title).nonEmpty
            let end = dates.date(record.value(c.end)).flatMap { $0 > start ? $0 : nil }
            return .row(ImportRow(workoutKey: startText + "|" + (title ?? ""), startedAt: start, exercise: exercise,
                                  set: set, workoutName: title, endedAt: end,
                                  workoutNote: record.value(c.description).nonEmpty,
                                  supersetGroup: record.value(c.superset).nonEmpty))
        }
    }
}
