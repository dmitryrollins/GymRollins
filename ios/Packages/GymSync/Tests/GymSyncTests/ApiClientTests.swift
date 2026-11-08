import Foundation
import Testing
@testable import GymSync

/// `ApiClient` against a stub: the bearer, JSON, `ApiError`, the offline cases and the 401 signal.
@Suite struct ApiClientTests {
    private let session = StoredSession(token: "t1.sig", userId: UUID(), email: "a@test.local")
    private let signedOut = #"{"error": {"code": "signed_out", "message": "Sign in required."}}"#

    @Test func sendsTheStoredTokenAsABearerAndJSON() async throws {
        let server = StubServer { _ in .json(200, #"{"ok": true}"#) }
        let api = server.client(sessions: InMemorySessionStore(session))
        let _: [String: Bool] = try await api.post("/v1/sync/routines", ["rows": [String]()])
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "\(server.baseURL.absoluteString)/v1/sync/routines")
        #expect(request.headers["Authorization"] == "Bearer t1.sig")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(try request.json() as? [String: [String]] == ["rows": []])
    }

    /// Read off the client's own session: URLSession runs no cookie handling or cache for a stub URLProtocol, so a
    /// round trip through the stub can't show either.
    @Test func neverSendsOrKeepsCookies() {
        let configuration = ApiClient(baseURL: URL(string: "http://127.0.0.1:9")!, sessions: InMemorySessionStore())
            .configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func clearSaysWhetherItForgotASession() throws {
        let sessions = InMemorySessionStore(session)
        #expect(!sessions.clear(ifToken: "t2.sig"))
        #expect(sessions.load() == session)
        #expect(sessions.clear(ifToken: session.token))
        #expect(sessions.load() == nil)
        #expect(!sessions.clear(ifToken: nil), "nothing left to forget")
        try sessions.save(session)
        #expect(sessions.clear(ifToken: nil))
    }

    @Test func anErrorAnswerBecomesApiErrorWithItsCodeAndStatus() async throws {
        let server = StubServer { _ in
            .json(422, #"{"error": {"code": "row_rejected", "message": "rows[0].policy is required"}}"#)
        }
        await #expect(throws: ApiError(status: 422, code: "row_rejected", message: "rows[0].policy is required")) {
            let _: [String: String] = try await server.client().get("/v1/sync/routines")
        }
    }

    @Test func anAnswerInAnotherShapeStillGivesTheStatus() async throws {
        let server = StubServer { _ in
            StubAnswer(status: 502, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8))
        }
        do {
            let _: [String: String] = try await server.client().get("/v1/sync/routines")
            Issue.record("expected an error")
        } catch let error as ApiError {
            #expect(error.status == 502)
            #expect(error.code == "http_502")
            #expect(error.isTemporary)
        }
    }

    @Test func networkFailuresRateLimitsAndServerErrorsAreOffline() {
        #expect(ApiError.isOffline(URLError(.notConnectedToInternet)))
        #expect(ApiError.isOffline(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        for status in [429, 500, 503] { #expect(ApiError.isOffline(ApiError(status: status, code: "x", message: ""))) }
        for status in [400, 401, 403, 404, 409, 413, 422] {
            #expect(!ApiError.isOffline(ApiError(status: status, code: "x", message: "")))
        }
    }

    @Test(.timeLimit(.minutes(1))) func a401ToTheStoredTokenForgetsItAndSaysSo() async throws {
        let answer = signedOut
        let server = StubServer { _ in .json(401, answer) }
        let sessions = InMemorySessionStore(session)
        let api = server.client(sessions: sessions)
        await #expect(throws: ApiError(status: 401, code: "signed_out", message: "Sign in required.")) {
            let _: [String: String] = try await api.get("/v1/sync/routines")
        }
        #expect(sessions.load() == nil)
        var signals = api.unauthorized.makeAsyncIterator()
        #expect(await signals.next() != nil)
    }

    @Test func a401ToAnOlderTokenLeavesASessionSignedInSince() async throws {
        let sessions = InMemorySessionStore(session)
        let newer = StoredSession(token: "t2.sig", userId: session.userId, email: nil)
        let answer = signedOut
        let server = StubServer { _ in
            try sessions.save(newer) // a sign-in finishing while the old request was on the wire
            return .json(401, answer)
        }
        await #expect(throws: ApiError.self) {
            let _: [String: String] = try await server.client(sessions: sessions).get("/v1/sync/routines")
        }
        #expect(sessions.load() == newer)
    }

    @Test func a401ToAnOlderTokenSendsNoSignal() async throws {
        let sessions = InMemorySessionStore(session)
        let newer = StoredSession(token: "t2.sig", userId: session.userId, email: nil)
        let answer = signedOut
        let server = StubServer { _ in
            try sessions.save(newer)
            return .json(401, answer)
        }
        let api = server.client(sessions: sessions)
        await #expect(throws: ApiError.self) {
            let _: [String: String] = try await api.get("/v1/sync/routines")
        }
        #expect(await !signalled(api), "the session signed in since stays signed in")
    }

    @Test func a401ToASignInLeavesTheStoreAloneAndSendsNoSignal() async throws {
        let server = StubServer { _ in
            .json(401, #"{"error": {"code": "invalid_email_or_password", "message": "Invalid email or password"}}"#)
        }
        let sessions = InMemorySessionStore(session)
        let api = server.client(sessions: sessions)
        await #expect(throws: ApiError.self) {
            _ = try await api.data("POST", "/api/auth/sign-in/email", body: Data("{}".utf8), bearer: .anonymous)
        }
        #expect(sessions.load() == session)
        #expect(await !signalled(api))
    }

    @Test func a401ToASignOutLeavesTheStoreAloneAndSendsNoSignal() async throws {
        let answer = signedOut
        let server = StubServer { _ in .json(401, answer) }
        let sessions = InMemorySessionStore(session)
        let api = server.client(sessions: sessions)
        let token = session.token
        await #expect(throws: ApiError.self) {
            _ = try await api.data("POST", "/api/auth/sign-out", body: Data("{}".utf8), bearer: .token(token))
        }
        #expect(sessions.load() == session, "even when the token it carried is the stored one")
        #expect(await !signalled(api))
    }

    @Test func aRedirectComesBackAsItIsAndTheBearerStaysHome() async throws {
        let elsewhere = StubServer { _ in .json(200, "{}") }
        let target = elsewhere.baseURL.appending(path: "/v1/sync/routines").absoluteString
        let server = StubServer { _ in .json(302, "{}", headers: ["Location": target]) }
        let api = server.client(sessions: InMemorySessionStore(session))
        let error = await #expect(throws: ApiError.self) {
            let _: [String: String] = try await api.get("/v1/sync/routines")
        }
        #expect(error?.status == 302)
        #expect(server.requests.count == 1)
        #expect(elsewhere.requests.isEmpty, "the bearer never follows a redirect")
    }

    @Test func aRequestTheAppBuiltWrongIsNotOffline() {
        #expect(!ApiError.isOffline(URLError(.badURL)))
        #expect(!ApiError.isOffline(URLError(.unsupportedURL)))
        #expect(!ApiError.isOffline(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)))
        #expect(ApiError.isOffline(URLError(.cancelled)), "a cancelled request is tried again later")
    }

    @Test func aSessionOrABearerNeverShowsItsToken() {
        let bearer = ApiClient.Bearer.token(session.token)
        var printed = ""
        print(session, bearer, to: &printed)
        var dumped = ""
        dump(session, to: &dumped)
        dump(bearer, to: &dumped)
        let shown = [printed, dumped, "\(session)", "\(bearer)", String(reflecting: session), String(reflecting: bearer)]
        for text in shown {
            #expect(!text.contains(session.token), "\(text)")
            #expect(text.contains("<redacted>"), "\(text)")
        }
    }

    @Test func aRequestWithoutASessionCarriesNoAuthorization() async throws {
        let server = StubServer { _ in .json(200, "{}") }
        let _: [String: String] = try await server.client().get("/api/auth/get-session")
        #expect(server.requests.first?.headers["Authorization"] == nil)
    }

    @Test func aPlusInTheQueryReachesTheServerAsAPlus() async throws {
        let server = StubServer { _ in .json(200, "{}") }
        let _: [String: String] = try await server.client().get("/v1/sync/exercise-prefs",
                                                                query: [URLQueryItem(name: "after", value: "a+b")])
        let request = try #require(server.requests.first)
        #expect(request.url.query(percentEncoded: true) == "after=a%2Bb")
        #expect(request.query["after"] == "a+b")
    }
}

/// Whether `api.unauthorized` yields within a moment. The client buffers a signal before it throws, so one arrives at
/// once; without one the wait wins.
private func signalled(_ api: ApiClient) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var signals = api.unauthorized.makeAsyncIterator()
            return await signals.next() != nil
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(200))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}
