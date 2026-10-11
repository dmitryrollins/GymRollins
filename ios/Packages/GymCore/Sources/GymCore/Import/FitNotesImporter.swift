import Foundation

/// FitNotes' "Spreadsheet Export" CSV: `Date,Exercise,Category,Weight (kg),Weight (lbs),Reps,Distance,
/// Distance Unit,Time,Notes,Kind` (older Android builds: one `Weight (kgs)` or `Weight (lbs)` column; some write
/// `Comment`). Dates only (`yyyy-MM-dd`), so each day becomes one workout starting at local noon. `Time` is a
/// per-set `MM:ss` / `HH:MM:ss`. No warm-up, superset or RPE data; `Category` and `Kind` are ignored.
public enum FitNotesImporter: WorkoutImporter {
    public static let source = ImportSource.fitNotes
    public static let expectedHeader = ["Date", "Exercise", "Category", "Weight (kg)", "Weight (lbs)", "Reps",
                                        "Distance", "Distance Unit", "Time", "Notes", "Kind"]
    private static let required = ["date", "exercise", "category", "reps"]
    private static let kgColumns = ["Weight (kg)", "Weight (kgs)"]
    private static let lbColumns = ["Weight (lbs)", "Weight (lb)"]
    static let noonHour = 12

    public static func recognizes(header: [String]) -> Bool {
        let keys = ImportTable.keys(header)
        return keys.isSuperset(of: required) && keys.contains { $0.hasPrefix("weight") }
    }

    /// Only a bare `Weight` column with no `Weight Unit` column leaves the unit unknown.
    public static func needsWeightUnit(header: [String]) -> Bool {
        let keys = ImportTable.keys(header)
        let named = (kgColumns + lbColumns).map(ImportTable.key)
        return !keys.contains { named.contains($0) } && !keys.contains("weight unit")
    }

    private struct Columns {
        let date, exercise, kg, lb, weight, weightUnit, reps, distance, distanceUnit, time, notes: Int?

        /// Header width: every row must have at least this many fields.
        let count: Int

        init(_ t: ImportTable) {
            count = t.header.count
            date = t.column("Date"); exercise = t.column("Exercise")
            kg = kgColumns.lazy.compactMap { t.column($0) }.first
            lb = lbColumns.lazy.compactMap { t.column($0) }.first
            weight = t.column("Weight"); weightUnit = t.column("Weight Unit"); reps = t.column("Reps")
            distance = t.column("Distance"); distanceUnit = t.column("Distance Unit"); time = t.column("Time")
            notes = t.column("Notes", "Comment")
        }
    }

    public static func parse(_ text: String, options: ImportOptions) throws -> WorkoutImportResult {
        let table = try ImportTable(text)
        guard recognizes(header: table.header) else { throw WorkoutImportError.unrecognizedHeader(table.header) }
        let columns = Columns(table)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = options.timeZone
        let outcomes = table.rows.map { record -> ImportRowOutcome in
            parseRow(record, columns: columns, options: options) { noon(of: $0, calendar: calendar) }
        }
        return ImportAssembler.result(outcomes, source: source) { key, _, _ in ImportID.make([source.rawValue, key]) }
    }

    private static func parseRow(_ record: CSVParser.CSVRecord, columns c: Columns, options: ImportOptions,
                                 date parseDate: (String) -> Date?) -> ImportRowOutcome {
        let line = record.line
        if let error = record.missingColumns(expected: c.count) { return .failure(error) }
        let dateText = record.value(c.date)
        guard let date = parseDate(dateText) else {
            return .failure(ImportRowError(line: line, message: "Unreadable date '\(dateText)'"))
        }
        let exercise = record.value(c.exercise)
        guard !exercise.isEmpty else { return .failure(ImportRowError(line: line, message: "Missing exercise name")) }
        var cells = ImportSetCells()
        switch weight(record, columns: c, fallback: options.weightUnit) {
        case .success(let (value, unit)): cells.weight = value; cells.weightUnit = unit
        case .failure(let message): return .failure(ImportRowError(line: line, message: message.text))
        }
        cells.reps = record.value(c.reps)
        if let message = applyDistanceAndTime(record, columns: c, to: &cells) {
            return .failure(ImportRowError(line: line, message: message))
        }
        cells.note = record.value(c.notes).nonEmpty
        switch cells.build(line: line) {
        case .failure(let error): return .failure(error)
        case .success(nil): return .ignored
        case .success(let set?): return .row(ImportRow(workoutKey: dateText, startedAt: date, exercise: exercise, set: set))
        }
    }

    private struct Message: Error { let text: String }

    /// Fills distance (unit column, default km) and `Time`; returns the row's error message, if any.
    private static func applyDistanceAndTime(_ record: CSVParser.CSVRecord, columns c: Columns,
                                             to cells: inout ImportSetCells) -> String? {
        cells.distance = record.value(c.distance)
        let unitText = record.value(c.distanceUnit)
        if !unitText.isEmpty {
            guard let unit = DistanceUnit(abbreviation: unitText) else { return "Unknown distance unit '\(unitText)'" }
            cells.distanceUnit = unit
        } else if !cells.distance.isEmpty {
            cells.distanceUnit = .kilometers
        }
        let timeText = record.value(c.time)
        guard !timeText.isEmpty else { return nil }
        guard let seconds = seconds(timeText) else { return "Unreadable time '\(timeText)'" }
        cells.durationSec = seconds
        return nil
    }

    /// The row's weight cell and unit: the kg or lb column that has a value, else `Weight` + `Weight Unit`.
    private static func weight(_ record: CSVParser.CSVRecord, columns c: Columns,
                               fallback: WeightUnit) -> Result<(String, WeightUnit), Message> {
        let kg = record.value(c.kg)
        if !kg.isEmpty { return .success((kg, .kg)) }
        let lb = record.value(c.lb)
        if !lb.isEmpty { return .success((lb, .lb)) }
        let value = record.value(c.weight)
        let unitText = record.value(c.weightUnit)
        guard !unitText.isEmpty else { return .success((value, fallback)) }
        guard let unit = ImportUnits.weight(unitText) else {
            return .failure(Message(text: "Unknown weight unit '\(unitText)'"))
        }
        return .success((value, unit))
    }

    /// Local noon of a `yyyy-MM-dd` date, built from components (not by parsing midnight first: in time zones
    /// whose DST switch skips midnight, that day's midnight doesn't exist). Nil for anything else or an invalid day.
    static func noon(of text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        let wanted = DateComponents(year: year, month: month, day: day, hour: noonHour)
        guard let date = calendar.date(from: wanted),
              calendar.dateComponents([.year, .month, .day, .hour], from: date) == wanted else { return nil }
        return date
    }

    /// `Time` as seconds: `MM:ss`, `HH:MM:ss`, or a plain number of seconds.
    static func seconds(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(":") { return StrongImporter.clockSeconds(trimmed) }
        guard case .number(let value) = ImportNumber.parse(trimmed), value.isFinite, value >= 0,
              value <= ImportBounds.durationSec.upperBound else { return nil }
        return Int(value.rounded())
    }
}
