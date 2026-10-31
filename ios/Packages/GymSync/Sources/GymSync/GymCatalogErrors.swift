import Foundation
import GymData
import Supabase

/// Turns what PostgREST, Storage and Auth throw into the few cases `ShareOutbox` reacts to: offline and signed-out
/// stop the queue, the rest settle one row. The server's own words are the function's `raise exception` messages.
enum GymCatalogErrors {
    private static let signedOutCodes: Set<String> = ["42501", "PGRST301", "PGRST302", "PGRST303"]

    static func map(_ error: Error) -> GymCatalogError {
        switch error {
        case let known as GymCatalogError: known
        case let failure as PostgrestError: map(message: failure.message, code: failure.code)
        case let failure as StorageError: mapStorage(failure)
        case is AuthError: .signedOut
        case let failure as HTTPError: failure.response.statusCode == 401 ? .signedOut : .rejected(failure.localizedDescription)
        case _ where AuthFailure.isNetwork(error): .offline
        default: .rejected(error.localizedDescription)
        }
    }

    /// Storage answers HTTP 400 for both a repeated name and a policy refusal; only the body tells them apart.
    static func isDuplicateUpload(_ error: StorageError) -> Bool {
        error.statusCode == "409" || error.error == "Duplicate"
    }

    private static func map(message: String, code: String?) -> GymCatalogError {
        switch message {
        case "daily_limit": return .dailyLimit
        case "gym_not_shareable": return .gymNotShareable
        case "photo_missing": return .photoMissing
        default: break
        }
        if let code, signedOutCodes.contains(code) { return .signedOut }
        return .rejected(message)
    }

    private static func mapStorage(_ error: StorageError) -> GymCatalogError {
        error.statusCode == "401" ? .signedOut : .rejected(error.message)
    }
}
