import Foundation

/// One app's CSV export format: recognizes its header row and parses the file into workouts.
public protocol WorkoutImporter {
    static var source: ImportSource { get }
    /// The header this importer documents (shown when a file isn't recognized).
    static var expectedHeader: [String] { get }
    /// True when `header` (the file's first row) is this app's export.
    static func recognizes(header: [String]) -> Bool
    /// True when the file doesn't say which weight unit it uses, so `ImportOptions.weightUnit` decides.
    static func needsWeightUnit(header: [String]) -> Bool
    static func parse(_ text: String, options: ImportOptions) throws -> WorkoutImportResult
}

public extension WorkoutImporter {
    static func needsWeightUnit(header: [String]) -> Bool { false }
}

/// Every supported format, with header-based detection and a single entry point that honors a user override.
public enum WorkoutImporters {
    /// Detection order. A computed list: metatypes of non-Sendable protocols can't be a `static let` in Swift 6.
    public static var all: [any WorkoutImporter.Type] { ImportSource.allCases.map(importer(for:)) }

    public static func importer(for source: ImportSource) -> any WorkoutImporter.Type {
        switch source {
        case .fitbod: FitbodImporter.self
        case .strong: StrongImporter.self
        case .hevy: HevyImporter.self
        case .fitNotes: FitNotesImporter.self
        }
    }

    /// The file's header row (first record, trimmed, delimiter detected), or nil for an empty file.
    public static func header(of text: String) -> [String]? {
        try? ImportTable(headerOnly: text).header
    }

    /// Which app exported `text`, judged from its header row alone.
    public static func detect(_ text: String) -> ImportSource? {
        guard let header = header(of: text) else { return nil }
        return all.first { $0.recognizes(header: header) }?.source
    }

    /// True when the file's weight unit must come from the user (see `WorkoutImporter.needsWeightUnit`).
    public static func needsWeightUnit(_ text: String, source: ImportSource?) -> Bool {
        guard let header = header(of: text), let resolved = source ?? detect(text) else { return false }
        return importer(for: resolved).needsWeightUnit(header: header)
    }

    /// Parses `text` as `source`'s export, or detects the format when `source` is nil (auto-detect).
    /// A file that is clearly another app's export than the one picked fails with `.sourceMismatch`.
    public static func parse(_ text: String, source: ImportSource?,
                             options: ImportOptions = ImportOptions()) throws -> WorkoutImportResult {
        guard let header = header(of: text) else { throw WorkoutImportError.emptyFile }
        let detected = all.first { $0.recognizes(header: header) }?.source
        guard let resolved = source ?? detected else { throw WorkoutImportError.unrecognizedHeader(header) }
        if let detected, detected != resolved {
            throw WorkoutImportError.sourceMismatch(selected: resolved, detected: detected)
        }
        return try importer(for: resolved).parse(text, options: options)
    }
}
