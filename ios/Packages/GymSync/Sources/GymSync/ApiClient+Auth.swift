import Foundation

// The Better Auth routes the app uses (server/src/auth/routes.ts lets only these five through), and DELETE /v1/account.
// What Better Auth 1.7.18 answers behind authHandler (checked in plan 27):
// - The sign-ins answer `{token, user}` (plus `redirect: false`) and the bearer plugin's `set-auth-token` header: the
//   same token, signed (`<token>.<signature>`). Either works as the bearer; the header's is kept.
// - `get-session` answers `{session, user}`, or `null` (status 200) when the token no longer holds. Renewing a session
//   moves its expiry only, so the token never changes.
// - `sign-out` answers 200 whatever the token.
// - Errors come in the API's shape, with Better Auth's codes lowercased (`invalid_email_or_password`, …).
extension ApiClient {
    func signInWithApple(idToken: String, nonce: String) async throws -> StoredSession {
        try await signIn("/api/auth/sign-in/social",
                         payload: AppleSignIn(provider: "apple", idToken: .init(token: idToken, nonce: nonce)))
    }

    #if DEBUG
    func signIn(email: String, password: String) async throws -> StoredSession {
        try await signIn("/api/auth/sign-in/email", payload: EmailSignIn(email: email, password: password))
    }

    /// Better Auth requires a name, and the app has none to give.
    func signUp(email: String, password: String) async throws -> StoredSession {
        try await signIn("/api/auth/sign-up/email", payload: EmailSignUp(email: email, password: password, name: ""))
    }
    #endif

    /// Whose the stored token is, or nil when the server no longer holds that session.
    func currentUser() async throws -> AuthUser? {
        let (body, _) = try await data("GET", "/api/auth/get-session")
        return try SyncJSON.decoder.decode(SessionAnswer?.self, from: body)?.user
    }

    /// Ends the session on the server. Sent with the token the phone has just forgotten, and with an empty JSON body:
    /// Better Auth answers a body-less POST from URLSession (`Content-Length: 0`) with 415.
    func signOut(token: String) async throws {
        _ = try await data("POST", "/api/auth/sign-out", body: Data("{}".utf8), bearer: .token(token))
    }

    /// `DELETE /v1/account`: 204, or 422 `photos_remain` while a photo of the account is stored.
    func deleteAccountOnServer() async throws {
        _ = try await data("DELETE", "/v1/account")
    }

    private func signIn<Payload: Encodable>(_ path: String, payload: Payload) async throws -> StoredSession {
        let (body, response) = try await data("POST", path, body: SyncJSON.encoder.encode(payload), bearer: .anonymous)
        let answer = try SyncJSON.decoder.decode(SignInAnswer.self, from: body)
        guard let token = response.value(forHTTPHeaderField: "set-auth-token") ?? answer.token, !token.isEmpty else {
            throw ApiError(status: response.statusCode, code: "no_session", message: "The server gave no session.")
        }
        return StoredSession(token: token, userId: answer.user.id, email: answer.user.email)
    }
}

/// Whose a session is. Better Auth's user ids are UUIDs (server/src/auth/auth.ts makes them).
struct AuthUser: Decodable, Sendable {
    let id: UUID
    let email: String?
}

private struct SignInAnswer: Decodable {
    let token: String?
    let user: AuthUser
}

private struct SessionAnswer: Decodable {
    let user: AuthUser
}

private struct AppleSignIn: Encodable {
    struct IdToken: Encodable {
        let token: String
        let nonce: String
    }

    let provider: String
    let idToken: IdToken
}

#if DEBUG
private struct EmailSignIn: Encodable {
    let email: String
    let password: String
}

private struct EmailSignUp: Encodable {
    let email: String
    let password: String
    let name: String
}
#endif
