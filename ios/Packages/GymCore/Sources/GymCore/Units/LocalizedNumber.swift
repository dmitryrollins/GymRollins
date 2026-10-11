import Foundation

/// Parses numbers typed into decimal-pad fields. Locales whose decimal keyboard inserts a comma ("82,5") and ones
/// that insert a dot ("82.5") both parse; surrounding whitespace is ignored. The single parser every numeric input
/// uses, so a value can't be accepted on one screen and rejected (or silently dropped) on another.
public enum LocalizedNumber {
    /// The finite value of `text`, or nil when it is empty or not a number.
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite ? $0 : nil }
    }
}
