import Foundation

/// Errors surfaced by GymData repositories for invalid caller input. Distinct from SwiftData's
/// own throwing surface so callers can pattern-match on user-input mistakes vs. persistence
/// failures.
public enum GymDataError: Error, Equatable {
    /// Caller-supplied input failed validation. The message is user-facing safe.
    case invalidInput(String)
}
