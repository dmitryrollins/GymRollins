import Foundation

/// The server refused a row: the API answered `row_rejected` or another 422 (a CHECK, NOT NULL or foreign key failure,
/// a wrong type, a cap), `too_large`, or `not_allowed` (the row's id is another account's). Retrying the same payload
/// can't succeed, so the engine records it per row and carries on with the rest of the round.
public struct SyncRecordRejected: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
