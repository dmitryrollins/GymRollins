import Foundation
import Observation

public enum AuthState: Equatable, Sendable {
    case signedOut
    case signedIn(userId: UUID, email: String?)

    public var userId: UUID? {
        if case .signedIn(let id, _) = self { return id }
        return nil
    }
}

/// An auth change from outside the service's own calls: the API answered 401 to the stored session (signed out
/// elsewhere, expired, the account deleted). Tests drive their own.
public enum AuthEvent: Sendable, Equatable {
    case signedIn(userId: UUID, email: String?)
    case signedOut
}

/// The photo steps of account deletion, kept apart so a failure can say which one broke. `detach` clears the photo
/// names on the server and on the phone, and changes nothing else; once it has succeeded the photos are as good as gone
/// for the user, so `remove` (deleting the objects) and the server step that follows say so when they fail.
public struct AccountPhotoSteps: Sendable {
    public let detach: @Sendable () async throws -> Void
    public let remove: @Sendable () async throws -> Void

    public init(detach: @escaping @Sendable () async throws -> Void, remove: @escaping @Sendable () async throws -> Void) {
        self.detach = detach
        self.remove = remove
    }
}

/// Sign-in on the API's Better Auth: Sign in with Apple with the id token the app gets (plus email and password in
/// DEBUG builds, for tests), sign-out, account deletion and session restore. Every failure is thrown as an
/// `AuthFailure` with a user-facing message. The session (Better Auth's bearer token, and whose it is) lives in
/// `api.sessions`, the Keychain on the phone, so `restore()` works offline. A 401 that ends it (to a call that carried
/// it, while it is still the stored one) signs the service out and is reported through `onExternalChange`; the local
/// data stays.
@MainActor @Observable
public final class AuthService {
    public private(set) var state: AuthState = .signedOut

    @ObservationIgnored public let api: ApiClient
    /// Called when an auth event (not one of this service's own calls) changed `state`.
    @ObservationIgnored public var onExternalChange: (@MainActor (AuthState) -> Void)?
    @ObservationIgnored private var observer: Task<Void, Never>?

    /// `events` replaces the API's 401 signal (tests inject their own).
    public init(api: ApiClient, events: AsyncStream<AuthEvent>? = nil) {
        self.api = api
        let stream = events ?? Self.events(from: api)
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

    /// Every 401 that ended the stored session; the client has already forgotten the token.
    private static func events(from api: ApiClient) -> AsyncStream<AuthEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in api.unauthorized { continuation.yield(.signedOut) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Restores the stored session on launch. The server says whether it still holds it (`get-session` answers `null`
    /// when it doesn't). Offline, or with the server busy, the stored account stays signed in, and sync reports
    /// `.offline` until the server answers. An answer the app can't read signs out for this launch and keeps the token.
    public func restore() async {
        guard let stored = api.sessions.load() else {
            state = .signedOut
            return
        }
        do {
            if let user = try await api.currentUser() {
                state = .signedIn(userId: user.id, email: user.email)
            } else {
                endSession(checked: stored.token)
            }
        } catch where ApiError.isOffline(error) {
            state = .signedIn(userId: stored.userId, email: stored.email)
        } catch let refused as ApiError where refused.status == 401 {
            // The client has forgotten the token it sent, if it was still the stored one, and has signalled.
            endSession(checked: stored.token)
        } catch {
            state = .signedOut
        }
    }

    /// Added after review. `get-session` answered `null` (or 401) about `token`. Signs out only if that is still the
    /// stored token: a sign-in that finished while the request was on the wire stays signed in. Reports the change
    /// like any external one.
    private func endSession(checked token: String) {
        guard api.sessions.clear(ifToken: token) else { return }
        state = .signedOut
        onExternalChange?(.signedOut)
    }

    public func signInWithApple(idToken: String, nonce: String) async throws {
        try await authenticate(.signIn) { try await self.api.signInWithApple(idToken: idToken, nonce: nonce) }
    }

    #if DEBUG
    /// Email/password sign-in, for tests and the local Worker only (the server takes it with ALLOW_PASSWORD_AUTH=1).
    public func signIn(email: String, password: String) async throws {
        try await authenticate(.signIn) { try await self.api.signIn(email: email, password: password) }
    }

    /// Email/password sign-up, for tests only.
    public func signUp(email: String, password: String) async throws {
        try await authenticate(.signUp) { try await self.api.signUp(email: email, password: password) }
    }
    #endif

    /// Signs out. The phone forgets the session before telling the server, so it is signed out even when that request
    /// fails (offline, say); the server's copy then just expires. Better Auth answers 200 even for a session already
    /// gone.
    public func signOut() async throws {
        let stored = api.sessions.load()
        api.sessions.clear()
        state = .signedOut
        guard let stored else { return }
        do {
            try await api.signOut(token: stored.token)
        } catch where ApiError.isOffline(error) {
            // Forgotten here; the server's copy expires on its own.
        } catch {
            throw AuthFailure(error, during: .signOut)
        }
    }

    /// Detaches and removes the user's photos through `photos`, then deletes the account and all its data on the
    /// server (`DELETE /v1/account`, which refuses with `photos_remain` while a photo is left), then forgets the
    /// session. A failure leaves the account and the session, so the user can try again; the message says whether the
    /// photos are already gone.
    public func deleteAccount(photos: AccountPhotoSteps? = nil) async throws {
        try await deleteAccount(photos: photos) { try await self.api.deleteAccountOnServer() }
    }

    func deleteAccount(photos: AccountPhotoSteps?, onServer: () async throws -> Void) async throws {
        guard api.sessions.load() != nil else { throw AuthFailure.sessionExpired }
        // A session the server no longer holds would fail only after the photos are gone.
        let holds: Bool
        do {
            holds = try await api.currentUser() != nil
        } catch {
            throw AuthFailure(error, during: .deleteAccount)
        }
        guard holds else { throw AuthFailure.sessionExpired }
        if let photos { try await removePhotos(photos) }
        do {
            try await onServer()
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            throw photos == nil ? AuthFailure(error, during: .deleteAccount) : AuthFailure.afterPhotos(error)
        }
        // The account is gone, and its sessions with it.
        api.sessions.clear()
        state = .signedOut
    }

    /// Detach, then remove. A failed detach changed nothing; a failed remove has already detached, which the message
    /// owns up to.
    private func removePhotos(_ photos: AccountPhotoSteps) async throws {
        do { try await photos.detach() } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            throw AuthFailure.detachFailed
        }
        do { try await photos.remove() } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            throw AuthFailure.afterPhotos(error)
        }
    }

    private func authenticate(_ action: AuthAction, _ call: () async throws -> StoredSession) async throws {
        do {
            let session = try await call()
            try api.sessions.save(session)
            state = .signedIn(userId: session.userId, email: session.email)
        } catch {
            throw AuthFailure(error, during: action)
        }
    }
}
