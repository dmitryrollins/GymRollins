import CryptoKit
import Foundation

/// A parsed CSV: trimmed header plus data records, with the delimiter detected from the header line.
struct ImportTable {
    let header: [String]
    let rows: [CSVParser.CSVRecord]

    init(_ text: String) throws(WorkoutImportError) {
        let records = CSVParser.records(text, delimiter: CSVParser.detectDelimiter(text))
        guard let first = records.first else { throw .emptyFile }
        header = first.fields.map { $0.trimmingCharacters(in: .whitespaces) }
        rows = Array(records.dropFirst())
    }

    /// Reads just the first non-blank line, for format detection without parsing the whole file.
    init(headerOnly text: String) throws(WorkoutImportError) {
        let body = text.drop { $0 == "\u{FEFF}" || $0.isNewline }
        let line = body.prefix { !$0.isNewline }
        try self.init(String(line))
    }

    /// Index of the first column whose normalized name is one of `names`.
    func column(_ names: String...) -> Int? {
        let wanted = Set(names.map(Self.key))
        return header.firstIndex { wanted.contains(Self.key($0)) }
    }

    /// Header cell as compared for detection: lowercased, trimmed, inner whitespace collapsed.
    static func key(_ cell: String) -> String {
        cell.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func keys(_ header: [String]) -> Set<String> { Set(header.map(key)) }
}

extension CSVParser.CSVRecord {
    /// Trimmed field at `index`; empty when the column is absent or the row is short.
    func value(_ index: Int?) -> String {
        guard let index, fields.indices.contains(index) else { return "" }
        return fields[index].trimmingCharacters(in: .whitespaces)
    }

    /// A row error when the record has fewer fields than the header: a truncated row must be reported, not read
    /// as empty cells and silently ignored.
    func missingColumns(expected: Int) -> ImportRowError? {
        guard fields.count < expected else { return nil }
        return ImportRowError(line: line, message: "Row is missing columns (found \(fields.count), expected \(expected))")
    }
}

/// Number cells: `.` or a lone `,` as the decimal separator (decimal-comma locales), empty allowed.
enum ImportNumber {
    enum Parsed: Equatable {
        case empty
        case number(Double)
        case invalid
    }

    static func parse(_ raw: String) -> Parsed {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .empty }
        let commas = text.filter { $0 == "," }.count
        let normalized = commas == 1 && !text.contains(".") ? text.replacingOccurrences(of: ",", with: ".") : text
        guard let value = Double(normalized) else { return .invalid }
        return .number(value)
    }
}

/// Shared sanity limits for every importer (same as the original Fitbod importer's).
enum ImportBounds {
    static let reps: ClosedRange<Double> = 0...1_000
    static let weightKg: ClosedRange<Double> = 0...1_000
    static let durationSec: ClosedRange<Double> = 0...86_400
    static let distanceM: ClosedRange<Double> = 0...1_000_000
    static let rpe: ClosedRange<Double> = 0...10
}

/// Raw set cells from any export, validated and converted to kg / seconds / meters.
struct ImportSetCells {
    var weight = ""
    var weightUnit = WeightUnit.kg
    var reps = ""
    /// Seconds as a number cell; ignored when `durationSec` is already known (e.g. parsed from `MM:ss`).
    var seconds = ""
    var durationSec: Int?
    var distance = ""
    var distanceUnit = DistanceUnit.meters
    var rpe = ""
    var warmup = false
    var note: String?

    /// The set, `nil` when the row carries no work (no reps, time or distance), or the row's error.
    func build(line: Int) -> Result<ImportedSet?, ImportRowError> {
        func number(_ cell: String) -> Double?? {
            switch ImportNumber.parse(cell) {
            case .empty: .some(nil)
            case .number(let value): .some(value)
            case .invalid: nil
            }
        }
        guard let weight = number(weight), let reps = number(reps), let secondsCell = number(seconds),
              let distance = number(distance), let rpe = number(rpe) else {
            return .failure(ImportRowError(line: line, message: "Unreadable number in row"))
        }
        let weightKg = UnitConverter.toKg(weight ?? 0, from: weightUnit)
        let repCount = reps ?? 0
        let duration = durationSec.map(Double.init) ?? secondsCell ?? 0
        let meters = distanceUnit.toMeters(distance ?? 0)
        let values = [weightKg, repCount, duration, meters, rpe ?? 0]
        guard values.allSatisfy(\.isFinite), ImportBounds.weightKg.contains(weightKg),
              ImportBounds.reps.contains(repCount), ImportBounds.durationSec.contains(duration),
              ImportBounds.distanceM.contains(meters), rpe.map(ImportBounds.rpe.contains) ?? true else {
            return .failure(ImportRowError(line: line, message: "Value out of range"))
        }
        guard repCount == repCount.rounded() else {
            return .failure(ImportRowError(line: line, message: "Reps must be a whole number"))
        }
        guard repCount > 0 || duration > 0 || meters > 0 else { return .success(nil) }
        return .success(ImportedSet(weightKg: weightKg, reps: Int(repCount),
                                    durationSec: duration > 0 ? Int(duration.rounded()) : nil,
                                    distanceM: meters > 0 ? meters : nil, warmup: warmup, note: note,
                                    rpe: rpe.flatMap { $0 > 0 ? $0 : nil }))
    }
}

/// One accepted CSV row: a set plus the workout it belongs to.
struct ImportRow {
    /// Rows with the same key form one workout.
    let workoutKey: String
    let startedAt: Date
    let exercise: String
    let set: ImportedSet
    var workoutName: String?
    var endedAt: Date?
    var workoutNote: String?
    var supersetGroup: String?
}

/// What one CSV record turned into.
enum ImportRowOutcome {
    case row(ImportRow)
    /// Deliberately skipped (not an error): rest-timer rows, rows with no set data.
    case ignored
    case failure(ImportRowError)
}

enum ImportAssembler {
    /// Groups accepted rows into workouts (exercise order = first appearance) and collects row errors.
    static func result(_ outcomes: [ImportRowOutcome], source: ImportSource,
                       id: (_ key: String, _ first: ImportRow, _ names: [String]) -> UUID) -> WorkoutImportResult {
        var rows: [ImportRow] = []
        var errors: [ImportRowError] = []
        var ignored = 0
        for outcome in outcomes {
            switch outcome {
            case .row(let row): rows.append(row)
            case .ignored: ignored += 1
            case .failure(let error): errors.append(error)
            }
        }
        return WorkoutImportResult(workouts: group(rows, id: id), rowErrors: errors,
                                   warmupSetCount: rows.filter(\.set.warmup).count, rowCount: outcomes.count,
                                   source: source, ignoredRowCount: ignored)
    }

    private static func group(_ rows: [ImportRow],
                              id: (String, ImportRow, [String]) -> UUID) -> [ImportedWorkout] {
        let byKey = Dictionary(grouping: rows, by: \.workoutKey)
        return byKey.compactMap { key, dayRows -> ImportedWorkout? in
            guard let first = dayRows.first else { return nil }
            let names = dayRows.map(\.exercise).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            // One entry per exercise and superset group (first appearance order): the same exercise in two
            // supersets stays two entries. Rows without a group (every Fitbod row) merge by name as before.
            struct EntryKey: Hashable { let exercise: String; let group: String? }
            let keys = dayRows.map { EntryKey(exercise: $0.exercise, group: $0.supersetGroup) }
                .reduce(into: [EntryKey]()) { if !$0.contains($1) { $0.append($1) } }
            let byEntry = Dictionary(grouping: dayRows) { EntryKey(exercise: $0.exercise, group: $0.supersetGroup) }
            let entries = keys.map { entryKey in
                ImportedEntry(exerciseName: entryKey.exercise, sets: (byEntry[entryKey] ?? []).map(\.set),
                              supersetGroup: entryKey.group)
            }
            return ImportedWorkout(id: id(key, first, names), startedAt: first.startedAt, entries: entries,
                                   name: first.workoutName, endedAt: dayRows.lazy.compactMap(\.endedAt).first,
                                   note: dayRows.lazy.compactMap(\.workoutNote).first)
        }
        .sorted { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt }
    }
}

/// Deterministic workout ids: SHA-256 of the parts joined with `|`, first 16 bytes. Re-importing the same export
/// yields the same ids, so the import overwrites instead of duplicating.
enum ImportID {
    static func make(_ parts: [String]) -> UUID {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Reads timestamps with a fixed list of formats (POSIX locale, strict), trying each in order.
struct ImportDateParser {
    private let formatters: [DateFormatter]

    init(formats: [String], timeZone: TimeZone) {
        formatters = formats.map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = format
            f.isLenient = false
            return f
        }
    }

    func date(_ text: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

extension String {
    /// nil when empty after trimming.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ImportUnits {
    /// `kg`/`kgs`/`lb`/`lbs` (any case) as written in unit columns and header suffixes.
    static func weight(_ text: String) -> WeightUnit? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "kg", "kgs", "kilogram", "kilograms": .kg
        case "lb", "lbs", "pound", "pounds": .lb
        default: nil
        }
    }
}
