import Foundation

/// Fitbod's "Export workout data" CSV: one row per set, kg, rows grouped into workouts by identical `Date`.
public enum FitbodImporter: WorkoutImporter {
    public static let source = ImportSource.fitbod
    public static let expectedHeader = ["Date", "Exercise", "Reps", "Weight(kg)", "Duration(s)", "Distance(m)",
                                        "Incline", "Resistance", "isWarmup", "Note", "multiplier"]

    private static let multiplierBounds: ClosedRange<Double> = 0...10

    public static func recognizes(header: [String]) -> Bool {
        header.map(ImportTable.key) == expectedHeader.map(ImportTable.key)
    }

    public static func parse(_ text: String) throws -> WorkoutImportResult {
        try parse(text, options: ImportOptions())
    }

    /// Fitbod writes explicit offsets and kg, so `options` doesn't change anything.
    public static func parse(_ text: String, options: ImportOptions) throws -> WorkoutImportResult {
        let table = try ImportTable(text)
        guard recognizes(header: table.header) else { throw WorkoutImportError.unrecognizedHeader(table.header) }
        let dates = ImportDateParser(formats: ["yyyy-MM-dd HH:mm:ss Z"], timeZone: options.timeZone)
        let outcomes = table.rows.map { record -> ImportRowOutcome in
            switch parseRow(record, dates: dates) {
            case .success(let row): .row(row)
            case .failure(let error): .failure(error)
            }
        }
        // Id = hash of the timestamp and the exercise names, unchanged since the first Fitbod import shipped.
        return ImportAssembler.result(outcomes, source: source) { key, _, names in ImportID.make([key] + names) }
    }

    private static func parseRow(_ record: CSVParser.CSVRecord,
                                 dates: ImportDateParser) -> Result<ImportRow, ImportRowError> {
        let line = record.line
        guard record.fields.count == expectedHeader.count else {
            return .failure(ImportRowError(line: line, message: "Expected 11 columns, found \(record.fields.count)"))
        }
        let v = record.fields.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let date = dates.date(v[0]) else {
            return .failure(ImportRowError(line: line, message: "Unreadable date '\(v[0])'"))
        }
        guard !v[1].isEmpty else { return .failure(ImportRowError(line: line, message: "Missing exercise name")) }
        guard let reps = Double(v[2]), let weight = Double(v[3]), let duration = Double(v[4]),
              let distance = Double(v[5]), let multiplier = Double(v[10]) else {
            return .failure(ImportRowError(line: line, message: "Unreadable number in row"))
        }
        guard reps == reps.rounded() else {
            return .failure(ImportRowError(line: line, message: "Reps must be a whole number"))
        }
        guard reps.isFinite, weight.isFinite, duration.isFinite, distance.isFinite, multiplier.isFinite,
              ImportBounds.reps.contains(reps), ImportBounds.weightKg.contains(weight),
              ImportBounds.durationSec.contains(duration), ImportBounds.distanceM.contains(distance),
              multiplierBounds.contains(multiplier) else {
            return .failure(ImportRowError(line: line, message: "Value out of range"))
        }
        let set = ImportedSet(weightKg: weight, reps: Int(reps), durationSec: duration > 0 ? Int(duration) : nil,
                              distanceM: distance > 0 ? distance : nil, warmup: v[8].lowercased() == "true",
                              multiplier: multiplier > 0 ? multiplier : 1, note: v[9].isEmpty ? nil : v[9])
        return .success(ImportRow(workoutKey: v[0], startedAt: date, exercise: v[1], set: set))
    }
}
