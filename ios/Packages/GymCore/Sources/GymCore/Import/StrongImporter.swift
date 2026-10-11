import Foundation

/// Strong's "Export Strong Data" CSV. Two known layouts, read by column name:
/// - current (comma): `Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,Notes,
///   Workout Notes,RPE` — weights in the app's unit setting (not in the file, so `ImportOptions.weightUnit`),
///   distance in meters;
/// - older Android (semicolon): adds `Weight Unit` / `Distance Unit` per row and `Workout Duration`.
/// `Set Order` is the set number, `W` (warm-up), `D` (drop set) or `F` (failure); `Rest Timer` / `Note` rows are
/// not sets. Timestamps are local wall-clock time (`yyyy-MM-dd HH:mm:ss`).
public enum StrongImporter: WorkoutImporter {
    public static let source = ImportSource.strong
    public static let expectedHeader = ["Date", "Workout Name", "Duration", "Exercise Name", "Set Order", "Weight",
                                        "Reps", "Distance", "Seconds", "Notes", "Workout Notes", "RPE"]
    private static let required = ["date", "workout name", "exercise name", "set order", "weight", "reps"]
    private static let nonSetOrders: Set<String> = ["rest timer", "note"]

    public static func recognizes(header: [String]) -> Bool {
        ImportTable.keys(header).isSuperset(of: required)
    }

    public static func needsWeightUnit(header: [String]) -> Bool {
        !ImportTable.keys(header).contains("weight unit")
    }

    private struct Columns {
        let date, name, duration, exercise, setOrder, weight, weightUnit, reps: Int?
        let distance, distanceUnit, seconds, notes, workoutNotes, rpe: Int?

        /// Header width: every row must have at least this many fields.
        let count: Int

        init(_ t: ImportTable) {
            count = t.header.count
            date = t.column("Date"); name = t.column("Workout Name")
            duration = t.column("Duration", "Workout Duration"); exercise = t.column("Exercise Name")
            setOrder = t.column("Set Order"); weight = t.column("Weight"); weightUnit = t.column("Weight Unit")
            reps = t.column("Reps"); distance = t.column("Distance"); distanceUnit = t.column("Distance Unit")
            seconds = t.column("Seconds"); notes = t.column("Notes"); workoutNotes = t.column("Workout Notes")
            rpe = t.column("RPE")
        }
    }

    public static func parse(_ text: String, options: ImportOptions) throws -> WorkoutImportResult {
        let table = try ImportTable(text)
        guard recognizes(header: table.header) else { throw WorkoutImportError.unrecognizedHeader(table.header) }
        let columns = Columns(table)
        let dates = ImportDateParser(formats: ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss"],
                                     timeZone: options.timeZone)
        let outcomes = table.rows.map { parseRow($0, columns: columns, dates: dates, options: options) }
        return ImportAssembler.result(outcomes, source: source) { key, _, _ in ImportID.make([source.rawValue, key]) }
    }

    private static func parseRow(_ record: CSVParser.CSVRecord, columns c: Columns, dates: ImportDateParser,
                                 options: ImportOptions) -> ImportRowOutcome {
        let line = record.line
        if let error = record.missingColumns(expected: c.count) { return .failure(error) }
        let order = record.value(c.setOrder)
        if nonSetOrders.contains(order.lowercased()) { return .ignored }
        let dateText = record.value(c.date)
        guard let date = dates.date(dateText) else {
            return .failure(ImportRowError(line: line, message: "Unreadable date '\(dateText)'"))
        }
        let exercise = record.value(c.exercise)
        guard !exercise.isEmpty else { return .failure(ImportRowError(line: line, message: "Missing exercise name")) }
        var cells = ImportSetCells()
        cells.weight = record.value(c.weight)
        cells.reps = record.value(c.reps)
        cells.seconds = record.value(c.seconds)
        cells.distance = record.value(c.distance)
        if let message = applyUnits(record, columns: c, fallback: options.weightUnit, to: &cells) {
            return .failure(ImportRowError(line: line, message: message))
        }
        cells.rpe = record.value(c.rpe)
        cells.warmup = order.uppercased() == "W"
        cells.note = record.value(c.notes).nonEmpty
        switch cells.build(line: line) {
        case .failure(let error): return .failure(error)
        case .success(nil): return .ignored
        case .success(let set?):
            let title = record.value(c.name).nonEmpty
            let ended = durationSeconds(record.value(c.duration)).map { date.addingTimeInterval(TimeInterval($0)) }
            return .row(ImportRow(workoutKey: dateText + "|" + (title ?? ""), startedAt: date, exercise: exercise,
                                  set: set, workoutName: title, endedAt: ended,
                                  workoutNote: record.value(c.workoutNotes).nonEmpty))
        }
    }

    /// Per-row `Weight Unit` / `Distance Unit` (older Android export), else the chosen weight unit and meters.
    private static func applyUnits(_ record: CSVParser.CSVRecord, columns c: Columns, fallback: WeightUnit,
                                   to cells: inout ImportSetCells) -> String? {
        let unitText = record.value(c.weightUnit)
        if unitText.isEmpty {
            cells.weightUnit = fallback
        } else {
            guard let unit = ImportUnits.weight(unitText) else { return "Unknown weight unit '\(unitText)'" }
            cells.weightUnit = unit
        }
        let distanceUnitText = record.value(c.distanceUnit)
        if !distanceUnitText.isEmpty {
            guard let unit = DistanceUnit(abbreviation: distanceUnitText) else {
                return "Unknown distance unit '\(distanceUnitText)'"
            }
            cells.distanceUnit = unit
        }
        return nil
    }

    /// Strong's workout duration: `1h 5m`, `41m`, `2h`, `45s`, or clock style `42:15` / `1:02:03`.
    static func durationSeconds(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(":") { return clockSeconds(trimmed) }
        var total = 0
        var digits = ""
        var sawUnit = false
        for ch in trimmed where !ch.isWhitespace {
            if ch.isNumber {
                digits.append(ch)
                guard digits.count <= maxDigits else { return nil }
            } else {
                guard let value = Int(digits), let scale = ["h": 3_600, "m": 60, "s": 1][String(ch)] else { return nil }
                total += value * scale
                digits = ""
                sawUnit = true
            }
        }
        return sawUnit && digits.isEmpty ? total : nil
    }

    /// Longest number accepted in a duration part (keeps the arithmetic far from overflow).
    private static let maxDigits = 6

    /// `MM:ss` or `HH:MM:ss`.
    static func clockSeconds(_ text: String) -> Int? {
        let raw = text.split(separator: ":", omittingEmptySubsequences: false)
        guard raw.allSatisfy({ $0.count <= maxDigits }) else { return nil }
        let parts = raw.map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let values = parts.compactMap { $0 }
        guard values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }
}
