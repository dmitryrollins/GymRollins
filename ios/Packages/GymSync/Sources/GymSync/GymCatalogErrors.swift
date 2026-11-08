import Foundation
import GymData

/// Turns what the API throws into the few cases `ShareOutbox` reacts to: offline and signed-out stop the queue, the
/// rest settle one row. The codes are the server's (server/src/gyms/refusals.ts, spec section 6): the strings the app
/// always matched, so each reaches the same case and the app shows the same message.
enum GymCatalogErrors {
    /// `hasSession` matters for 403: with no session the caller is signed out; with one, the server refused this row
    /// (not allowed here), and the queue goes on with the next.
    static func map(_ error: Error, hasSession: Bool = false) -> GymCatalogError {
        switch error {
        case let known as GymCatalogError: known
        case let failure as ApiError: map(api: failure, hasSession: hasSession)
        case _ where AuthFailure.isNetwork(error): .offline
        default: .rejected(error.localizedDescription)
        }
    }

    /// The code first, then the status.
    private static func map(api failure: ApiError, hasSession: Bool) -> GymCatalogError {
        switch failure.code {
        case "daily_limit": return .dailyLimit
        case "gym_not_shareable": return .gymNotShareable
        case "photo_missing": return .photoMissing
        case "gym_full": return .gymFull
        case "photo_in_use": return .photoInUse
        case "unknown_target": return .unknownTarget
        case "place_taken": return .placeTaken
        // A CHECK or clean_text refused the text: on a report, its note.
        case "row_rejected": return .noteRefused
        case _ where failure.code.hasPrefix("photo_"): return .photoRefused
        default: break
        }
        switch failure.status {
        case 401: return .signedOut
        case 403: return hasSession ? .notAllowed : .signedOut
        case _ where failure.isTemporary: return .offline
        default: return .rejected(failure.message)
        }
    }
}
