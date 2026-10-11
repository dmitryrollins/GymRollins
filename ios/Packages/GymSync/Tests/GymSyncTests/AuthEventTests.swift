import Foundation
import Testing
@testable import GymSync

@MainActor
@Suite struct AuthEventTests {
    private func service() -> (AuthService, AsyncStream<AuthEvent>.Continuation) {
        let (stream, continuation) = AsyncStream<AuthEvent>.makeStream()
        let config = SupabaseConfig(url: URL(string: "http://127.0.0.1:9")!, anonKey: "anon")
        return (AuthService(client: config.makeClient(storage: InMemoryAuthStorage()), events: stream), continuation)
    }

    @Test func externalSignOutUpdatesStateAndNotifies() async throws {
        let (auth, events) = service()
        var seen: [AuthState] = []
        auth.onExternalChange = { seen.append($0) }
        let user = UUID()

        events.yield(.signedIn(userId: user, email: "a@test.local"))
        try await waitFor { auth.state == .signedIn(userId: user, email: "a@test.local") }

        // e.g. the SDK's token refresh found the session revoked.
        events.yield(.signedOut)
        try await waitFor { auth.state == .signedOut }
        #expect(seen == [.signedIn(userId: user, email: "a@test.local"), .signedOut])
    }

    @Test func repeatedEventsNotifyOnce() async throws {
        let (auth, events) = service()
        var count = 0
        auth.onExternalChange = { _ in count += 1 }
        events.yield(.signedOut) // already signed out: nothing changes
        let user = UUID()
        events.yield(.signedIn(userId: user, email: nil))
        events.yield(.signedIn(userId: user, email: nil)) // token refresh for the same user
        try await waitFor { auth.state.userId == user }
        // Events are handled in order: once this sentinel is handled, the duplicate before it was too.
        events.yield(.signedOut)
        try await waitFor { auth.state == .signedOut }
        #expect(count == 2) // the sign-in once (not twice), then the sentinel sign-out
    }
}
