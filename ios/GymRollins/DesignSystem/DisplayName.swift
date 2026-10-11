import Foundation

enum DisplayName {
    private static let upper: Set<String> = ["ez", "db", "bb", "sz", "rdl"]

    /// "barbell bench press" -> "Barbell Bench Press"; keeps punctuation, uppercases known abbreviations.
    static func of(_ raw: String) -> String {
        raw.split(separator: " ", omittingEmptySubsequences: false).map { word in
            word.split(separator: "-", omittingEmptySubsequences: false).map { part -> String in
                let lower = part.lowercased()
                if upper.contains(lower) { return lower.uppercased() }
                if lower.hasPrefix("(") { return "(" + capitalizeFirst(String(lower.dropFirst())) }
                return capitalizeFirst(lower)
            }.joined(separator: "-")
        }.joined(separator: " ")
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
