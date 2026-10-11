import Supabase
import Foundation
import Testing
@testable import GymSync

@Suite struct AuthFailureTests {
    private func apiError(_ code: ErrorCode, status: Int = 400) -> AuthError {
        let url = URL(string: "http://127.0.0.1:55421/auth/v1/token")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return .api(message: "server says no", errorCode: code, underlyingData: Data(), underlyingResponse: response)
    }

    @Test func networkErrorsAskToCheckTheConnection() {
        #expect(AuthFailure(URLError(.notConnectedToInternet), during: .signIn).message
            == "Couldn't sign in. Check your connection and try again.")
        #expect(AuthFailure(URLError(.timedOut), during: .signUp).message
            == "Couldn't create your account. Check your connection and try again.")
        #expect(AuthFailure(URLError(.cannotConnectToHost), during: .deleteAccount).message
            == "Couldn't delete your account. Check your connection and try again.")
        let nsError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        #expect(AuthFailure(nsError, during: .signIn).message
            == "Couldn't sign in. Check your connection and try again.")
    }

    @Test func wrongCredentials() {
        #expect(AuthFailure(apiError(.invalidCredentials), during: .signIn).message == "Wrong email or password.")
    }

    @Test func existingAccount() {
        let expected = "An account with this email already exists. Sign in instead."
        #expect(AuthFailure(apiError(.emailExists, status: 422), during: .signUp).message == expected)
        #expect(AuthFailure(apiError(.userAlreadyExists, status: 422), during: .signUp).message == expected)
    }

    @Test func weakPassword() {
        let expected = "That password is too weak. Use at least 8 characters."
        #expect(AuthFailure(AuthError.weakPassword(message: "weak", reasons: ["length"]), during: .signUp).message
            == expected)
        #expect(AuthFailure(apiError(.weakPassword, status: 422), during: .signUp).message == expected)
    }

    @Test func rateLimited() {
        #expect(AuthFailure(apiError(.overRequestRateLimit, status: 429), during: .signIn).message
            == "Too many attempts. Wait a minute and try again.")
    }

    @Test func expiredSession() {
        let expected = "Your session has expired. Please sign in again."
        #expect(AuthFailure(AuthError.sessionMissing, during: .deleteAccount).message == expected)
        #expect(AuthFailure(apiError(.refreshTokenNotFound), during: .restore).message == expected)
        #expect(AuthFailure(apiError(.sessionNotFound, status: 403), during: .deleteAccount).message == expected)
    }

    @Test func disabledProvider() {
        #expect(AuthFailure(apiError(.providerDisabled), during: .signIn).message
            == "This sign-in method isn't available right now.")
        #expect(AuthFailure(apiError(.signupDisabled, status: 422), during: .signUp).message
            == "This sign-in method isn't available right now.")
    }

    @Test func anythingElseIsGeneric() {
        struct Boom: Error {}
        #expect(AuthFailure(Boom(), during: .signIn).message == "Couldn't sign in. Please try again.")
        #expect(AuthFailure(apiError(.unexpectedFailure, status: 500), during: .signUp).message
            == "Couldn't create your account. Please try again.")
        #expect(AuthFailure(Boom(), during: .signOut).message == "Couldn't sign out. Please try again.")
        #expect(AuthFailure(Boom(), during: .deleteAccount).message == "Couldn't delete your account. Please try again.")
    }

    @Test func alreadyMappedFailuresPassThrough() {
        let failure = AuthFailure(message: "Custom")
        #expect(AuthFailure(failure, during: .signIn) == failure)
        #expect(failure.errorDescription == "Custom")
    }
}

@Suite struct SupabaseConfigTests {
    @Test func readsInfoDictionary() throws {
        let config = try SupabaseConfig(info: ["SUPABASE_URL": "http://127.0.0.1:55421", "SUPABASE_ANON_KEY": "anon"])
        #expect(config.url == URL(string: "http://127.0.0.1:55421"))
        #expect(config.anonKey == "anon")
    }

    @Test func rejectsMissingOrEmptyKeys() {
        #expect(throws: SupabaseConfigError.missing("SUPABASE_URL")) {
            try SupabaseConfig(info: ["SUPABASE_ANON_KEY": "anon"])
        }
        #expect(throws: SupabaseConfigError.missing("SUPABASE_ANON_KEY")) {
            try SupabaseConfig(info: ["SUPABASE_URL": "http://127.0.0.1:55421", "SUPABASE_ANON_KEY": "  "])
        }
    }

    @Test func rejectsUnexpandedOrSchemelessURLs() {
        // `http:/$()/host` in an xcconfig expands to `http://host`; an unexpanded build setting must not slip through.
        for raw in ["$(SUPABASE_URL)", "127.0.0.1:55421", "ftp://example.com", "http://"] {
            #expect(throws: SupabaseConfigError.invalidURL(raw)) {
                try SupabaseConfig(info: ["SUPABASE_URL": raw, "SUPABASE_ANON_KEY": "anon"])
            }
        }
    }

    @Test func readsEnvironment() throws {
        let config = try SupabaseConfig(environment: ["SUPABASE_URL": "https://abc.supabase.co",
                                                      "SUPABASE_ANON_KEY": "key"])
        #expect(config.url.host() == "abc.supabase.co")
    }
}

@MainActor
@Suite struct AuthServiceTests {
    private func service() throws -> AuthService {
        let config = SupabaseConfig(url: URL(string: "http://127.0.0.1:9")!, anonKey: "anon")
        return AuthService(client: config.makeClient(storage: InMemoryAuthStorage()))
    }

    @Test func startsSignedOut() throws {
        #expect(try service().state == .signedOut)
    }

    @Test func restoreWithoutAStoredSessionStaysSignedOut() async throws {
        let auth = try service()
        await auth.restore()
        #expect(auth.state == .signedOut)
        #expect(auth.state.userId == nil)
    }

    @Test func signOutWithoutASessionIsANoOp() async throws {
        let auth = try service()
        try await auth.signOut()
        #expect(auth.state == .signedOut)
    }

    @Test func deleteAccountWhileSignedOutFailsWithoutCallingTheServer() async throws {
        let auth = try service()
        await #expect(throws: AuthFailure(message: "Your session has expired. Please sign in again.")) {
            try await auth.deleteAccount()
        }
    }

    @Test func inMemoryStorageRoundTrips() throws {
        let storage = InMemoryAuthStorage()
        try storage.store(key: "k", value: Data([1, 2]))
        #expect(try storage.retrieve(key: "k") == Data([1, 2]))
        try storage.remove(key: "k")
        #expect(try storage.retrieve(key: "k") == nil)
    }
}
