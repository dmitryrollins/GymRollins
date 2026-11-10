import Foundation

/// What the user was trying to do when an auth call failed (shapes the message).
public enum AuthAction: Sendable {
    case signIn, signUp, signOut, deleteAccount, restore

    var failedVerb: String {
        switch self {
        case .signIn, .restore: "sign in"
        case .signUp: "create your account"
        case .signOut: "sign out"
        case .deleteAccount: "delete your account"
        }
    }
}

/// An auth error translated into a message the account screen can show as-is.
public struct AuthFailure: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(message: String) { self.message = message }

    public var errorDescription: String? { message }

    public init(_ error: Error, during action: AuthAction) {
        if let already = error as? AuthFailure {
            self = already
        } else if Self.isNetwork(error) {
            message = "Couldn't \(action.failedVerb). Check your connection and try again."
        } else if Self.isPhotosRemain(error) {
            message = Messages.photosRemain
        } else if let known = Self.knownMessage(for: error) {
            message = known
        } else {
            message = "Couldn't \(action.failedVerb). Please try again."
        }
    }

    /// Detaching the photos failed: nothing was changed, and the account is still there.
    static let detachFailed = AuthFailure(message: Messages.detachFailed)

    /// The stored session is missing, or the server no longer holds it.
    static let sessionExpired = AuthFailure(message: Messages.sessionExpired)

    /// The photos were detached (and perhaps removed) but the account is still there. A new upload that slipped in
    /// meanwhile gets its own words, since trying again is all it takes.
    static func afterPhotos(_ error: Error) -> AuthFailure {
        AuthFailure(message: isPhotosRemain(error) ? Messages.photoStillUploading : Messages.photosGoneAccountStays)
    }

    private static func isPhotosRemain(_ error: Error) -> Bool {
        (error as? ApiError)?.code == "photos_remain"
    }

    static func isNetwork(_ error: Error) -> Bool {
        error is URLError || (error as NSError).domain == NSURLErrorDomain
    }

    /// The API's codes, Better Auth's lowercased by the server (the ones plan 27's probe saw), then the status.
    private static func knownMessage(for error: Error) -> String? {
        guard let failure = error as? ApiError else { return nil }
        switch failure.code {
        case "invalid_email_or_password", "invalid_password", "credential_account_not_found":
            return Messages.wrongCredentials
        case "user_already_exists", "user_already_exists_use_another_email":
            return Messages.accountExists
        case "password_too_short":
            return Messages.weakPassword
        case "signed_out", "session_expired":
            return Messages.sessionExpired
        case "email_password_disabled", "email_password_sign_up_disabled", "provider_not_found",
             "id_token_not_supported":
            return Messages.methodUnavailable
        default:
            return failure.status == 429 ? Messages.rateLimited : nil
        }
    }

    private enum Messages {
        static let wrongCredentials = "Wrong email or password."
        static let accountExists = "An account with this email already exists. Sign in instead."
        static let weakPassword = "That password is too weak. Use at least 8 characters."
        static let rateLimited = "Too many attempts. Wait a minute and try again."
        static let sessionExpired = "Your session has expired. Please sign in again."
        static let photosRemain = "Couldn't delete your account because some photos are still being removed. Please try again."
        static let detachFailed = "Couldn't delete your account. Check your connection and try again."
        static let photosGoneAccountStays = "Your photos were removed, but your account wasn't deleted. "
            + "Check your connection and try again."
        static let photoStillUploading = "Your photos were removed, but a new one was still uploading, so your account "
            + "wasn't deleted. Please try again."
        static let methodUnavailable = "This sign-in method isn't available right now."
    }
}
