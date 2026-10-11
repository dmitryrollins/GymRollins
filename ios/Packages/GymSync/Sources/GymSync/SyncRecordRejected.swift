import Foundation

/// The server refused a row because of its values (Postgres SQLSTATE class 22 "data exception", e.g. 22001 value
/// too long, or class 23 "integrity constraint violation", e.g. 23514 CHECK / 23503 foreign key). Retrying the same
/// payload can't succeed, so the engine records it per row and carries on with the rest of the round.
public struct SyncRecordRejected: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// Whether a SQLSTATE means "this row's data is invalid" (as opposed to auth, permissions or server trouble).
    public static func isRowRejection(code: String?) -> Bool {
        guard let code else { return false }
        return code.hasPrefix("22") || code.hasPrefix("23")
    }
}
