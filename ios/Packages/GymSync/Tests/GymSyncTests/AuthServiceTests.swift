import Foundation
import GymData
import Testing
@testable import GymSync

/// A log that photo steps and the stub server both write to, in order.
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var items: [String] { lock.withLock { entries } }
    func add(_ item: String) { lock.withLock { entries.append(item) } }
}

private let userId = UUID(uuidString: "b73f3bdc-18c8-400a-b492-4db321b4baee")!
/// Better Auth 1.7.18's answers as plan 27's probe recorded them, trimmed.
private let signInBody = #"{"redirect": false, "token": "raw-token", "#
    + #""user": {"id": "b73f3bdc-18c8-400a-b492-4db321b4baee", "#
    + #""email": "a@test.local", "name": "", "emailVerified": true}}"#
private let sessionBody = #"{"session": {"token": "raw-token", "userId": "b73f3bdc-18c8-400a-b492-4db321b4baee"}, "#
    + #""user": {"id": "b73f3bdc-18c8-400a-b492-4db321b4baee", "email": "a@test.local", "name": ""}}"#
private let signedOutBody = #"{"error": {"code": "signed_out", "message": "Sign in required."}}"#
/// The bearer plugin's `set-auth-token`: the token and its signature, as sent.
private let signedToken = "raw-token.c2lnbmF0dXJl+/="
private let stored = StoredSession(token: signedToken, userId: userId, email: "a@test.local")

@Suite struct AuthFailureTests {
    private func api(_ status: Int, _ code: String) -> ApiError { ApiError(status: status, code: code, message: "no") }

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
        #expect(AuthFailure(api(401, "invalid_email_or_password"), during: .signIn).message
            == "Wrong email or password.")
    }

    @Test func existingAccount() {
        let expected = "An account with this email already exists. Sign in instead."
        #expect(AuthFailure(api(422, "user_already_exists_use_another_email"), during: .signUp).message == expected)
        #expect(AuthFailure(api(422, "user_already_exists"), during: .signUp).message == expected)
    }

    @Test func weakPassword() {
        #expect(AuthFailure(api(400, "password_too_short"), during: .signUp).message
            == "That password is too weak. Use at least 8 characters.")
    }

    @Test func rateLimited() {
        #expect(AuthFailure(api(429, "auth_failed"), during: .signIn).message
            == "Too many attempts. Wait a minute and try again.")
    }

    @Test func expiredSession() {
        let expected = "Your session has expired. Please sign in again."
        #expect(AuthFailure.sessionExpired.message == expected)
        #expect(AuthFailure(api(401, "signed_out"), during: .deleteAccount).message == expected)
        #expect(AuthFailure(api(401, "session_expired"), during: .restore).message == expected)
    }

    @Test func disabledMethod() {
        let expected = "This sign-in method isn't available right now."
        #expect(AuthFailure(api(400, "email_password_disabled"), during: .signIn).message == expected)
        #expect(AuthFailure(api(400, "email_password_sign_up_disabled"), during: .signUp).message == expected)
        #expect(AuthFailure(api(404, "provider_not_found"), during: .signIn).message == expected)
    }

    @Test func anythingElseIsGeneric() {
        struct Boom: Error {}
        #expect(AuthFailure(Boom(), during: .signIn).message == "Couldn't sign in. Please try again.")
        #expect(AuthFailure(api(401, "invalid_token"), during: .signIn).message
                == "Couldn't sign in. Please try again.",
                "Apple's token refused: audience, nonce, signature or expiry")
        #expect(AuthFailure(api(500, "server_error"), during: .signUp).message
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

/// `AuthService` against a stub of the Better Auth routes and `/v1/account`.
@MainActor
@Suite struct AuthServiceTests {
    private func service(_ server: StubServer, sessions: InMemorySessionStore = InMemorySessionStore()) -> AuthService {
        AuthService(api: server.client(sessions: sessions))
    }

    /// Signed in, against a server that still holds the session. Keep the server: its host goes with it.
    private func signedIn() async -> (AuthService, StubServer) {
        let server = StubServer { _ in .json(200, sessionBody) }
        let auth = service(server, sessions: InMemorySessionStore(stored))
        await auth.restore()
        return (auth, server)
    }

    private func steps(_ calls: StepLog, detach: (@Sendable () async throws -> Void)? = nil,
                       remove: (@Sendable () async throws -> Void)? = nil) -> AccountPhotoSteps {
        AccountPhotoSteps(detach: { try await detach?(); calls.add("detach") },
                          remove: { try await remove?(); calls.add("remove") })
    }

    @Test func startsSignedOut() {
        let server = StubServer { _ in .json(500, "{}") }
        #expect(service(server).state == .signedOut)
    }

    @Test func signInWithAppleSendsTheTokenAndNonceAndKeepsTheSession() async throws {
        let server = StubServer { _ in .json(200, signInBody, headers: ["set-auth-token": signedToken]) }
        let sessions = InMemorySessionStore()
        let auth = service(server, sessions: sessions)
        try await auth.signInWithApple(idToken: "apple.id.token", nonce: "raw-nonce")
        #expect(auth.state == .signedIn(userId: userId, email: "a@test.local"))
        #expect(sessions.load() == stored, "the signed token from set-auth-token")
        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/api/auth/sign-in/social")
        #expect(request.headers["Authorization"] == nil)
        let body = try #require(try request.json() as? [String: Any])
        #expect(body["provider"] as? String == "apple")
        #expect(body["idToken"] as? [String: String] == ["token": "apple.id.token", "nonce": "raw-nonce"])
    }

    @Test func theBodysTokenStandsInWhenTheHeaderIsMissing() async throws {
        let server = StubServer { _ in .json(200, signInBody) }
        let sessions = InMemorySessionStore()
        try await service(server, sessions: sessions).signIn(email: "a@test.local", password: "correct-horse")
        #expect(sessions.load()?.token == "raw-token")
        #expect(server.requests.first?.path == "/api/auth/sign-in/email")
    }

    @Test func signUpSendsTheEmptyNameBetterAuthRequires() async throws {
        let server = StubServer { _ in .json(200, signInBody, headers: ["set-auth-token": signedToken]) }
        let auth = service(server)
        try await auth.signUp(email: "a@test.local", password: "correct-horse")
        #expect(auth.state.userId == userId)
        #expect(server.requests.first?.path == "/api/auth/sign-up/email")
        let body = try #require(try server.requests.first?.json() as? [String: String])
        #expect(body == ["email": "a@test.local", "password": "correct-horse", "name": ""])
    }

    @Test func aRefusedSignInSaysWhyAndKeepsNothing() async throws {
        let server = StubServer { _ in
            .json(401, #"{"error": {"code": "invalid_email_or_password", "message": "Invalid email or password"}}"#)
        }
        let sessions = InMemorySessionStore()
        let auth = service(server, sessions: sessions)
        await #expect(throws: AuthFailure(message: "Wrong email or password.")) {
            try await auth.signIn(email: "a@test.local", password: "nope-nope-nope")
        }
        #expect(auth.state == .signedOut)
        #expect(sessions.load() == nil)
    }

    @Test func restoreAsksTheServerWithTheStoredToken() async throws {
        let server = StubServer { _ in .json(200, sessionBody) }
        let auth = service(server, sessions: InMemorySessionStore(stored))
        await auth.restore()
        #expect(auth.state == .signedIn(userId: userId, email: "a@test.local"))
        #expect(server.requests.map(\.path) == ["/api/auth/get-session"])
        #expect(server.requests.first?.headers["Authorization"] == "Bearer \(signedToken)")
    }

    @Test func restoreForgetsASessionTheServerNoLongerHolds() async throws {
        let server = StubServer { _ in .json(200, "null") }
        let sessions = InMemorySessionStore(stored)
        let auth = service(server, sessions: sessions)
        await auth.restore()
        #expect(auth.state == .signedOut)
        #expect(sessions.load() == nil)
    }

    /// Added after review: a sign-in that finishes while `get-session` is on the wire must not be signed out by the
    /// answer about the old token.
    @Test(arguments: [StubAnswer.json(200, "null"), StubAnswer.json(401, signedOutBody)])
    func restoreLeavesASignInThatFinishedWhileItWasAsking(answer: StubAnswer) async throws {
        let newer = StoredSession(token: "newer.c2ln", userId: UUID(), email: "b@test.local")
        let sessions = InMemorySessionStore(stored)
        let server = StubServer { _ in
            try sessions.save(newer) // the sign-in lands while the request is in flight
            return answer
        }
        let auth = service(server, sessions: sessions)
        auth.handle(.signedIn(userId: newer.userId, email: newer.email))
        var seen: [AuthState] = []
        auth.onExternalChange = { seen.append($0) }
        await auth.restore()
        #expect(auth.state == .signedIn(userId: newer.userId, email: "b@test.local"))
        #expect(sessions.load() == newer)
        #expect(seen.isEmpty)
    }

    @Test func restoreTellsTheCoordinatorWhenItSignsOutForReal() async throws {
        let server = StubServer { _ in .json(200, "null") }
        let sessions = InMemorySessionStore(stored)
        let auth = service(server, sessions: sessions)
        auth.handle(.signedIn(userId: userId, email: "a@test.local"))
        var seen: [AuthState] = []
        auth.onExternalChange = { seen.append($0) }
        await auth.restore()
        #expect(auth.state == .signedOut)
        #expect(sessions.load() == nil)
        #expect(seen == [.signedOut])
    }

    @Test func restoreOfflineOrWithTheServerBusyKeepsTheStoredAccount() async throws {
        for answer in [nil, StubAnswer.json(503, "{}")] {
            let server = StubServer { _ in
                guard let answer else { throw URLError(.notConnectedToInternet) }
                return answer
            }
            let sessions = InMemorySessionStore(stored)
            let auth = service(server, sessions: sessions)
            await auth.restore()
            #expect(auth.state == .signedIn(userId: userId, email: "a@test.local"))
            #expect(sessions.load() == stored)
        }
    }

    @Test func restoreWithoutAStoredSessionStaysSignedOutWithoutAsking() async throws {
        let server = StubServer { _ in .json(200, sessionBody) }
        let auth = service(server)
        await auth.restore()
        #expect(auth.state == .signedOut)
        #expect(server.requests.isEmpty)
    }

    @Test func signOutForgetsTheSessionThenTellsTheServer() async throws {
        let sessions = InMemorySessionStore(stored)
        let log = StepLog()
        let server = StubServer { _ in
            log.add(sessions.load() == nil ? "already forgotten" : "still stored")
            return .json(200, #"{"success": true}"#)
        }
        let auth = service(server, sessions: sessions)
        try await auth.signOut()
        #expect(auth.state == .signedOut)
        #expect(sessions.load() == nil)
        #expect(log.items == ["already forgotten"])
        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/api/auth/sign-out")
        #expect(request.headers["Authorization"] == "Bearer \(signedToken)")
        #expect(request.headers["Content-Type"] == "application/json", "Better Auth refuses a body-less POST with 415")
    }

    @Test func signOutOfflineStillSignsOut() async throws {
        let server = StubServer { _ in throw URLError(.notConnectedToInternet) }
        let sessions = InMemorySessionStore(stored)
        let auth = service(server, sessions: sessions)
        try await auth.signOut()
        #expect(auth.state == .signedOut)
        #expect(sessions.load() == nil)
    }

    @Test func signOutWithoutASessionIsANoOp() async throws {
        let server = StubServer { _ in .json(200, "{}") }
        try await service(server).signOut()
        #expect(server.requests.isEmpty)
    }

    @Test func a401FromTheAPISignsOutAndSaysSo() async throws {
        let server = StubServer { request in
            request.path == "/api/auth/get-session" ? .json(200, sessionBody) : .json(401, signedOutBody)
        }
        let sessions = InMemorySessionStore(stored)
        let auth = service(server, sessions: sessions)
        var seen: [AuthState] = []
        auth.onExternalChange = { seen.append($0) }
        await auth.restore()
        await #expect(throws: ApiError.self) { _ = try await auth.api.data("GET", "/v1/sync/profile") }
        try await waitFor { auth.state == .signedOut }
        #expect(seen == [.signedOut])
        #expect(sessions.load() == nil)
    }

    @Test func deleteAccountWhileSignedOutFailsWithoutCallingTheServer() async throws {
        let server = StubServer { _ in StubAnswer(status: 204, headers: [:], body: Data()) }
        await #expect(throws: AuthFailure(message: "Your session has expired. Please sign in again.")) {
            try await service(server).deleteAccount()
        }
        #expect(server.requests.isEmpty)
    }

    @Test func deleteAccountChecksTheSessionThenRemovesPhotosThenDeletes() async throws {
        let log = StepLog()
        let server = StubServer { request in
            log.add("\(request.method) \(request.path)")
            return request.path == "/api/auth/get-session"
                ? .json(200, sessionBody) : StubAnswer(status: 204, headers: [:], body: Data())
        }
        let sessions = InMemorySessionStore(stored)
        let auth = service(server, sessions: sessions)
        await auth.restore()
        try await auth.deleteAccount(photos: AccountPhotoSteps(
            detach: { log.add("detach") }, remove: { log.add("remove") }))
        #expect(log.items == ["GET /api/auth/get-session", "GET /api/auth/get-session", "detach", "remove",
                              "DELETE /v1/account"])
        #expect(auth.state == .signedOut)
        #expect(sessions.load() == nil)
    }

    @Test func aSessionTheServerNoLongerHoldsStopsDeletionBeforeThePhotos() async throws {
        let log = StepLog()
        let server = StubServer { _ in .json(200, "null") }
        let auth = service(server, sessions: InMemorySessionStore(stored))
        await #expect(throws: AuthFailure(message: "Your session has expired. Please sign in again.")) {
            try await auth.deleteAccount(photos: AccountPhotoSteps(detach: { log.add("detach") },
                                                                   remove: { log.add("remove") }))
        }
        #expect(log.items.isEmpty)
        #expect(server.requests.map(\.path) == ["/api/auth/get-session"])
    }

    @Test func aFailedDetachChangesNothingAndSaysSo() async throws {
        let (auth, server) = await signedIn()
        let calls = StepLog()
        struct Refused: Error {}
        let before = auth.state
        let failure = await #expect(throws: AuthFailure.self) {
            try await auth.deleteAccount(photos: steps(calls, detach: { throw Refused() })) { calls.add("server") }
        }
        #expect(calls.items.isEmpty, "no photo is removed and the account is not deleted")
        #expect(auth.state == before, "and the user stays signed in")
        #expect(failure?.message == "Couldn't delete your account. Check your connection and try again.")
        #expect(server.requests.count == 2, "restore, then the session check")
    }

    @Test func photosGoneButTheAccountStaysIsToldPlainly() async throws {
        let (auth, server) = await signedIn()
        let before = auth.state
        let expected = "Your photos were removed, but your account wasn't deleted. Check your connection and try again."
        struct NoPhotos: Error {}
        for failure in [URLError(.notConnectedToInternet) as Error, GymCatalogError.offline, NoPhotos()] {
            let calls = StepLog()
            let thrown = await #expect(throws: AuthFailure.self) {
                try await auth.deleteAccount(photos: steps(calls, remove: { throw failure })) { calls.add("server") }
            }
            #expect(thrown?.message == expected)
            #expect(calls.items == ["detach"], "the server step never ran")
        }
        let calls = StepLog()
        let thrown = await #expect(throws: AuthFailure.self) {
            try await auth.deleteAccount(photos: steps(calls)) { throw URLError(.timedOut) }
        }
        #expect(thrown?.message == expected, "the same words when the server step fails after the photos")
        #expect(auth.state == before, "the user stays signed in")
        #expect(server.requests.count == 5, "restore, then one session check per attempt")
    }

    @Test func aPhotoStillUploadingReadsAsRetryable() async throws {
        let (auth, server) = await signedIn()
        let thrown = await #expect(throws: AuthFailure.self) {
            try await auth.deleteAccount(photos: steps(StepLog())) {
                throw ApiError(status: 422, code: "photos_remain", message: "Delete your gym photos first.")
            }
        }
        #expect(thrown?.message == "Your photos were removed, but a new one was still uploading, so your account "
            + "wasn't deleted. Please try again.")
        #expect(server.requests.count == 2)
    }

    @Test func aRefusalForRemainingPhotosWithoutThePhotoStepKeepsTheOlderWords() {
        let refused = ApiError(status: 422, code: "photos_remain", message: "Delete your gym photos first.")
        #expect(AuthFailure(refused, during: .deleteAccount).message
            == "Couldn't delete your account because some photos are still being removed. Please try again.")
    }
}
