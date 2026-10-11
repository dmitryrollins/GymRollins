import Foundation
import Supabase
import GymCore
import GymData
import Testing
@testable import GymSync

/// `AuthService` against local Supabase Auth (email/password is DEBUG-only; the app uses Sign in with Apple).
@MainActor
@Suite(.enabled(if: supabaseConfigured, "Set SUPABASE_URL and SUPABASE_ANON_KEY to run against local Supabase"))
struct AuthIntegrationTests {
    @Test func signUpSignOutSignInAndRestore() async throws {
        let user = try await Account.signUp()
        guard case .signedIn(let id, let email) = user.auth.state else {
            Issue.record("expected signed in after sign-up")
            return
        }
        #expect(email == user.email)

        try await user.auth.signOut()
        #expect(user.auth.state == .signedOut)
        await user.auth.restore()
        #expect(user.auth.state == .signedOut)

        try await user.auth.signIn(email: user.email, password: IntegrationEnv.password)
        #expect(user.auth.state.userId == id)
        await user.auth.restore()  // from the stored session
        #expect(user.auth.state.userId == id)

        await #expect(throws: AuthFailure(message: "An account with this email already exists. Sign in instead.")) {
            try await Account.fresh(email: user.email).auth.signUp(email: user.email, password: IntegrationEnv.password)
        }
        try await user.deleteAccount()
    }

    @Test func wrongPasswordIsAFriendlyMessage() async throws {
        let user = try await Account.signUp()
        let other = try Account.fresh(email: user.email)
        await #expect(throws: AuthFailure(message: "Wrong email or password.")) {
            try await other.auth.signIn(email: user.email, password: "not-the-password")
        }
        #expect(other.auth.state == .signedOut)
        try await user.deleteAccount()
    }

    /// Deleting the account removes the user and every row they own (the script re-checks with admin SQL).
    @Test func deleteAccountRemovesUserAndData() async throws {
        let user = try await Account.signUp()
        let phone = try Device(user, clock: DeviceClock("2026-09-27T07:00:00Z"))
        defer { phone.tearDown() }
        try phone.profiles.save(Profile(unit: .kg))
        try phone.routines.upsert(Routine(name: "Push"))
        try phone.body.add(BodyweightEntry(date: phone.clock.now, weightKg: 81))
        try phone.workouts.save(finishedWorkout(name: "Push", at: phone.clock.now))
        await phone.engine.sync()
        #expect(phone.engine.status == .idle)
        let transport = user.transport
        let deletedId = user.userId

        try await user.deleteAccount()
        #expect(user.auth.state == .signedOut)
        #expect(user.auth.client.auth.currentSession == nil)
        // Signed out, the same client is the anon role, which has no table privileges at all.
        do {
            _ = try await transport.pullWorkouts(since: nil)
            Issue.record("anon read workouts")
        } catch let error as PostgrestError {
            #expect(error.code == "42501")
        }

        await #expect(throws: AuthFailure(message: "Wrong email or password.")) {
            try await Account.fresh(email: user.email).auth.signIn(email: user.email, password: IntegrationEnv.password)
        }
        // The email is free again, and the new account starts empty.
        let reborn = try Account.fresh(email: user.email)
        try await reborn.auth.signUp(email: user.email, password: IntegrationEnv.password)
        #expect(reborn.auth.state.userId != nil)
        #expect(reborn.auth.state.userId != deletedId)
        #expect(try await reborn.transport.pullWorkouts(since: nil).isEmpty)
        #expect(try await reborn.transport.pullRoutines(since: nil).isEmpty)
        try await reborn.deleteAccount()
    }
}
