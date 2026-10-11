import Foundation
import Observation
import Supabase

public enum AuthState: Equatable, Sendable {
    case signedOut
    case signedIn(userId: UUID, email: String?)

    public var userId: UUID? {
        if case .signedIn(let id, _) = self { return id }
        return nil
    }
}

/// An auth change reported by the SDK outside our own calls (e.g. its background token refresh found the session
/// revoked and signed out, or it refreshed the token of the current user).
public enum AuthEvent: Sendable, Equatable {
    case signedIn(userId: UUID, email: String?)
    case signedOut
}

/// Supabase Auth for the app: Sign in with Apple (plus email/password in DEBUG builds for tests), sign-out,
/// account deletion and session restore. Every failure is thrown as an `AuthFailure` with a user-facing message.
/// The session lives in the client's storage (the Keychain on device), so `restore()` works offline. The SDK's auth
/// events are observed for the service's lifetime: a session invalidated in the background updates `state` and is
/// reported through `onExternalChange`.
@MainActor @Observable
public final class AuthService {
    public private(set) var state: AuthState = .signedOut

    @ObservationIgnored public let client: SupabaseClient
    /// Called when an auth event (not one of this service's own calls) changed `state`.
    @ObservationIgnored public var onExternalChange: (@MainActor (AuthState) -> Void)?
    @ObservationIgnored private var observer: Task<Void, Never>?

    /// `events` replaces the SDK's auth-state stream (tests inject their own).
    public init(client: SupabaseClient, events: AsyncStream<AuthEvent>? = nil) {
        self.client = client
        let stream = events ?? Self.events(from: client)
        observer = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    isolated deinit { observer?.cancel() }

    func handle(_ event: AuthEvent) {
        let next: AuthState
        switch event {
        case .signedOut: next = .signedOut
        case let .signedIn(userId, email): next = .signedIn(userId: userId, email: email)
        }
        guard next != state else { return }
        state = next
        onExternalChange?(next)
    }

    /// The SDK's auth events that change who is signed in. `initialSession` is left to `restore()`, which also
    /// handles the offline case.
    private static func events(from client: SupabaseClient) -> AsyncStream<AuthEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await (event, session) in client.auth.authStateChanges {
                    switch event {
                    case .signedOut, .userDeleted:
                        continuation.yield(.signedOut)
                    case .signedIn, .tokenRefreshed, .userUpdated:
                        if let session { continuation.yield(.signedIn(userId: session.user.id, email: session.user.email)) }
                    default:
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Restores the stored session on launch. Offline, an expired stored session still counts as signed in
    /// (sync reports `.offline`, and the SDK refreshes the token once the network is back).
    public func restore() async {
        do {
            state = Self.signedIn(try await client.auth.session)
        } catch {
            if AuthFailure.isNetwork(error), let stored = client.auth.currentSession {
                state = Self.signedIn(stored)
            } else {
                state = .signedOut
            }
        }
    }

    public func signInWithApple(idToken: String, nonce: String) async throws {
        try await authenticate(.signIn) {
            try await self.client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
        }
    }

    #if DEBUG
    /// Email/password sign-in, for tests and the local stack only.
    public func signIn(email: String, password: String) async throws {
        try await authenticate(.signIn) {
            try await self.client.auth.signIn(email: email, password: password)
        }
    }

    /// Email/password sign-up (the local stack auto-confirms), for tests only.
    public func signUp(email: String, password: String) async throws {
        try await authenticate(.signUp) {
            let response = try await self.client.auth.signUp(email: email, password: password)
            guard let session = response.session else { throw AuthError.sessionMissing }
            return session
        }
    }
    #endif

    /// Signs out. The SDK drops the local session before telling the server, so the device is signed out even
    /// when that request fails (e.g. offline); the failure is not surfaced.
    public func signOut() async throws {
        do {
            try await client.auth.signOut()
        } catch where AuthFailure.isNetwork(error) {
            // Local session already removed; the server-side refresh token simply expires.
        } catch {
            state = .signedOut
            throw AuthFailure(error, during: .signOut)
        }
        state = .signedOut
    }

    /// Deletes the account and all its data on the server (`delete_my_account`), then signs out locally.
    public func deleteAccount() async throws {
        guard client.auth.currentSession != nil else { throw AuthFailure(AuthError.sessionMissing, during: .deleteAccount) }
        do {
            _ = try await client.auth.session // refreshes an expired access token first
            try await client.rpc("delete_my_account").execute()
        } catch {
            throw AuthFailure(error, during: .deleteAccount)
        }
        // The user no longer exists, so only the local session needs clearing (the SDK ignores the server's 404/403).
        do {
            try await client.auth.signOut(scope: .local)
        } catch {
            // Local session was removed before the request; nothing left to undo.
        }
        state = .signedOut
    }

    private func authenticate(_ action: AuthAction, _ call: @escaping () async throws -> Session) async throws {
        do {
            state = Self.signedIn(try await call())
        } catch {
            throw AuthFailure(error, during: action)
        }
    }

    private static func signedIn(_ session: Session) -> AuthState {
        .signedIn(userId: session.user.id, email: session.user.email)
    }
}
