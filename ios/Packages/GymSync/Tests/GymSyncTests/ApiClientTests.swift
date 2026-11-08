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

    @Test func neverSendsOrKeepsCookies() async throws {
        let server = StubServer { _ in .json(200, "{}", headers: ["Set-Cookie": "better-auth.session_token=abc; Path=/"]) }
        let api = server.client(sessions: InMemorySessionStore(session))
        let _: [String: String] = try await api.get("/api/auth/get-session")
        let _: [String: String] = try await api.get("/api/auth/get-session")
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.headers["Cookie"] == nil })
        let configuration = ApiClient.makeURLSession().configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
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
