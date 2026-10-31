import Foundation
import GymData
import Supabase

/// Turns what PostgREST, Storage and Auth throw into the few cases `ShareOutbox` reacts to: offline and signed-out
/// stop the queue, the rest settle one row. The server's own words are the function's `raise exception` messages.
enum GymCatalogErrors {
    private static let authCodes: Set<String> = ["PGRST301", "PGRST302", "PGRST303"]
    /// PostgREST's own "the database isn't reachable or is busy" answers, and Postgres classes 08 (connection) and
    /// 53 (resources, e.g. too many connections).
    /// What the bucket trigger raises (`guard_gym_photo`): the daily photo limit, a name a listing already uses, and
    /// names, types and owners that aren't allowed. A Storage version may show the message or only "row-level security".
    private static let photoRefusals: Set<String> = [
        "photo_daily_limit", "photo_name_in_use", "photo_bad_name", "photo_not_jpeg", "photo_immutable",
        "photo_owner_missing",
    ]
    private static let busyCodes: Set<String> = ["PGRST000", "PGRST001", "PGRST002", "PGRST003"]

    /// `hasSession` matters for 42501: with no session the caller is signed out; with one, the server refused this
    /// row (not allowed here), and the queue goes on with the next.
    static func map(_ error: Error, hasSession: Bool = false) -> GymCatalogError {
        switch error {
        case let known as GymCatalogError: known
        case let failure as PostgrestError: map(message: failure.message, code: failure.code, hasSession: hasSession)
        case let failure as StorageError: mapStorage(failure)
        case is AuthError: .signedOut
        case let failure as HTTPError: map(status: failure.response.statusCode, text: failure.localizedDescription)
        case _ where AuthFailure.isNetwork(error): .offline
        default: .rejected(error.localizedDescription)
        }
    }

    /// Storage answers HTTP 400 for both a repeated name and a policy refusal; only the body tells them apart.
    static func isDuplicateUpload(_ error: StorageError) -> Bool {
        error.statusCode == "409" || error.error == "Duplicate"
    }

    /// A busy or overloaded server is a reason to try again later, not a verdict on the row.
    static func isTemporary(status: Int) -> Bool { status == 429 || (500...599).contains(status) }

    private static func map(status: Int, text: String) -> GymCatalogError {
        if status == 401 { return .signedOut }
        return isTemporary(status: status) ? .offline : .rejected(text)
    }

    private static func map(message: String, code: String?, hasSession: Bool) -> GymCatalogError {
        switch message {
        case "daily_limit": return .dailyLimit
        case "gym_not_shareable": return .gymNotShareable
        case "photo_missing": return .photoMissing
        case "gym_full": return .gymFull
        case "photo_in_use": return .photoInUse
        case _ where photoRefusals.contains(message): return .photoRefused
        default: break
        }
        if let code {
            if authCodes.contains(code) { return .signedOut }
            if code == "42501" { return hasSession ? .notAllowed : .signedOut }
            if busyCodes.contains(code) || code.hasPrefix("08") || code.hasPrefix("53") { return .offline }
        }
        return .rejected(message)
    }

    /// The trigger on the buckets refuses an upload with a row-level-security error: the daily photo limit, or a
    /// name a listing already uses. Storage shows only that, as HTTP 400 `AccessDenied`, so every such refusal is one
    /// answer for the row. A repeated name (409 `Duplicate`) is told apart before this runs.
    private static func mapStorage(_ error: StorageError) -> GymCatalogError {
        if error.statusCode == "401" { return .signedOut }
        if let status = error.statusCode.flatMap(Int.init), isTemporary(status: status) { return .offline }
        if error.error == "AccessDenied" || photoRefusals.contains(error.message)
            || error.message.localizedCaseInsensitiveContains("row-level security") {
            return .photoRefused
        }
        return .rejected(error.message)
    }
}
