import Foundation
import Supabase

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
        } else if let known = Self.knownMessage(for: error) {
            message = known
        } else {
            message = "Couldn't \(action.failedVerb). Please try again."
        }
    }

    static func isNetwork(_ error: Error) -> Bool {
        error is URLError || (error as NSError).domain == NSURLErrorDomain
    }

    private static func knownMessage(for error: Error) -> String? {
        guard let authError = error as? AuthError else { return nil }
        switch authError {
        case .sessionMissing: return Messages.sessionExpired
        case .weakPassword: return Messages.weakPassword
        case .api(_, let code, _, _): return message(for: code)
        default: return nil
        }
    }

    private static func message(for code: ErrorCode) -> String? {
        switch code {
        case .invalidCredentials: Messages.wrongCredentials
        case .emailExists, .userAlreadyExists: Messages.accountExists
        case .weakPassword: Messages.weakPassword
        case .overRequestRateLimit: Messages.rateLimited
        case .sessionNotFound, .sessionExpired, .refreshTokenNotFound, .refreshTokenAlreadyUsed:
            Messages.sessionExpired
        case .providerDisabled, .signupDisabled, .emailProviderDisabled: Messages.methodUnavailable
        default: nil
        }
    }

    private enum Messages {
        static let wrongCredentials = "Wrong email or password."
        static let accountExists = "An account with this email already exists. Sign in instead."
        static let weakPassword = "That password is too weak. Use at least 8 characters."
        static let rateLimited = "Too many attempts. Wait a minute and try again."
        static let sessionExpired = "Your session has expired. Please sign in again."
        static let methodUnavailable = "This sign-in method isn't available right now."
    }
}
