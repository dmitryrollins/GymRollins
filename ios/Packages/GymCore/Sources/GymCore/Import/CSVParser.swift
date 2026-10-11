/// Minimal RFC 4180 parser: a single-character delimiter (comma by default; `;` and tab for locale variants),
/// double quotes with "" escapes, LF or CRLF, quoted newlines.
public enum CSVParser {
    public struct CSVRecord: Sendable, Equatable {
        /// 1-based starting line of this record in the source text.
        public let line: Int
        public let fields: [String]
    }

    public static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        records(text, delimiter: delimiter).map(\.fields)
    }

    /// Candidate delimiters, in tie-break order.
    private static let delimiters: [Character] = [",", ";", "\t"]

    /// The delimiter used by the first non-blank line (the header): whichever of `,` `;` tab occurs most often outside
    /// quotes. Comma wins ties and empty input. Apps that export in a decimal-comma locale use `;`.
    public static func detectDelimiter(_ text: String) -> Character {
        var counts: [Character: Int] = [:]
        var inQuotes = false
        for ch in text.drop(while: { $0 == "\u{FEFF}" || $0.isNewline }) {
            if ch == "\"" { inQuotes.toggle(); continue }
            if !inQuotes && ch.isNewline { break }
            if !inQuotes && delimiters.contains(ch) { counts[ch, default: 0] += 1 }
        }
        var best: Character = ","
        for candidate in delimiters where counts[candidate, default: 0] > counts[best, default: 0] { best = candidate }
        return best
    }

    /// Like `parse(_:)`, but keeps each record's 1-based starting line in the source text,
    /// counting newlines embedded in quoted fields and blank lines that were skipped.
    public static func records(_ text: String, delimiter: Character = ",") -> [CSVRecord] {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var out: [CSVRecord] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?
        var line = 1
        var rowLine = 1

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { out.append(CSVRecord(line: rowLine, fields: row)) }
            row = []
            rowLine = line
        }

        while let ch = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if ch == "\"" {
                    let next = iterator.next()
                    if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                } else {
                    if ch.isNewline { line += 1 }
                    field.append(ch)
                }
                continue
            }
            switch ch {
            case "\"" where field.isEmpty: inQuotes = true
            case delimiter: endField()
            case "\n", "\r\n": line += 1; endRow()
            case "\r": line += 1; endRow()
            default: field.append(ch)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return out
    }
}
