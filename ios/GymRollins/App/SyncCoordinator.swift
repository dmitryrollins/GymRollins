import Foundation
import GymData
import GymSync
import Observation
import os

/// Auth + sync lifecycle for the app. Owns the `AuthService` (nil when sync is disabled) and a `SyncEngine` that
/// exists only while signed in. Triggers: `start()` at launch, `setActive(true)` when the scene becomes active,
/// `localDataChanged()` (debounced), pull-to-refresh / "Sync now" (`syncNow()`), and a timer while active.
///
/// The local store belongs to one account (`SyncStore.ownerUserId`). Signing in adopts data that has no owner yet
/// (created before signing in); data owned by a different account is never uploaded under the new one: the owner
/// confirms removing it first (`accountSwitchPending`). A session invalidated elsewhere (revoked, expired refresh
/// token) drops the engine and shows the signed-out UI but keeps the data and its owner.
@MainActor
@Observable
final class SyncCoordinator {
    static let debounce: Duration = .seconds(2)
    static let periodicInterval: Duration = .seconds(5 * 60)

    let auth: AuthService?
    private(set) var engine: SyncEngine?
    /// Local rows not yet on the server (updated after every sync and local edit).
    private(set) var pendingChanges = 0
    /// Rows the server refused (their values break a server rule); shown in Account.
    private(set) var syncFailures: [SyncFailure] = []
    /// Signed in to an account other than the one that owns this iPhone's data; nothing syncs until the owner
    /// confirms removing the local copy (`confirmAccountSwitch()`) or backs out (`cancelAccountSwitch()`).
    var accountSwitchPending = false
    /// The account is being deleted: nothing may upload meanwhile, or a new photo would make the server refuse.
    var deletingAccount = false

    @ObservationIgnored let store: SyncStore
    @ObservationIgnored private let makeTransport: @MainActor (AuthService?) -> (any SyncTransport)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored let debouncer = SyncDebouncer(delay: SyncCoordinator.debounce)
    @ObservationIgnored private var periodic: Task<Void, Never>?
    @ObservationIgnored private var seenRemoteChanges = 0
    /// Called after a sync or conflict resolution wrote remote rows locally (the app reloads what it shows).
    @ObservationIgnored var onRemoteChanges: @MainActor () -> Void = {}
    /// Every finished round, changes or not (Apple Health waits for the first one before importing).
    @ObservationIgnored var onRoundFinished: @MainActor () -> Void = {}
    /// Runs after each pull to auto-apply Claude's pending proposals (when the owner allows it).
    @ObservationIgnored var autoApply: @MainActor () throws -> Int = { 0 }
    /// Called after sign-out / account switch / account deletion wiped the account's local copy.
    @ObservationIgnored var onLocalDataReset: @MainActor () -> Void = {}
    /// Called, before `onLocalDataReset`, when the wipe also erased the gyms (account deletion only). Sign-out and
    /// the account switch keep "This phone only" gyms.
    @ObservationIgnored var onGymDataErased: @MainActor () -> Void = {}
    /// Called once a sign-in or a restored session has settled and the account owns this phone's data: queued shares
    /// can go.
    @ObservationIgnored var onSignedIn: @MainActor () -> Void = {}
    /// Awaited at the start of a sign-out, while the session still works: the app clears what it left on the server
    /// for work that never finished (photos uploaded for queued shares).
    @ObservationIgnored var onWillSignOut: @MainActor () async -> Void = {}
    /// Called when the session is about to end or change (sign-out, account deletion or switch, a revoked session), before
    /// anything is wiped: work waiting on the server for the old session must not touch the rows when it comes back.
    /// Deletion calls it too, and the server may still say no; `onSessionEnded` is for what only a real end undoes.
    @ObservationIgnored var onSessionEnding: @MainActor () -> Void = {}
    /// Called once the session really is over: the sign-out wiped, the account deleted, or the session revoked.
    @ObservationIgnored var onSessionEnded: @MainActor () -> Void = {}
    /// Called when the server refused to delete the account: the session goes on, so what `onSessionEnding` stopped
    /// has to start again.
    @ObservationIgnored var onDeletionRefused: @MainActor () -> Void = {}
    /// The two photo steps of account deletion: detach the names (the phone then forgets them too), then remove the
    /// objects from Storage. The server refuses (`photos_remain`) while any are left.
    @ObservationIgnored var removePhotos: AccountPhotoSteps?
    /// What account deletion asks of the server, given the photo steps. Tests replace it to see what is passed.
    @ObservationIgnored lazy var deleteOnServer: @MainActor (AccountPhotoSteps?) async throws -> Void = {
        [weak self] photos in try await self?.auth?.deleteAccount(photos: photos)
    }
    /// Called when gyms got new ids (their old and new id): a sign-in as another account gave the phone's "This phone
    /// only" gyms ids of their own, or a pull found a gym deleted elsewhere that still held equipment kept here.
    @ObservationIgnored var onGymIdsMoved: @MainActor ([UUID: UUID]) -> Void = { _ in }
    /// The phone's gym photo files. The engine reads and downloads through it, and a sign-out deletes the files of
    /// the gym rows it removed through it (`wipeLocal`).
    @ObservationIgnored var gymPhotoFiles: (any GymPhotoFiles)?

    static let log = Logger(subsystem: "com.rollins.gymrollins", category: "sync")

    init(auth: AuthService?, store: SyncStore, now: @escaping () -> Date,
         makeTransport: @escaping @MainActor (AuthService?) -> (any SyncTransport)?) {
        self.auth = auth
        self.store = store
        self.now = now
        self.makeTransport = makeTransport
        auth?.onExternalChange = { [weak self] state in self?.authChangedElsewhere(state) }
    }

    /// Whether this build can sign in and sync at all (false in hermetic UI tests).
    var isAvailable: Bool { auth != nil }
    var authState: AuthState { auth?.state ?? .signedOut }
    var status: SyncStatus { engine?.status ?? .idle }
    var lastSyncedAt: Date? { engine?.lastSyncedAt }
    /// False until launch restored the stored session (`authState` reads signed-out until then); always true without
    /// a sync backend.
    var hasRestoredSession: Bool { auth == nil || restoredSession }
    @ObservationIgnored private var restoredSession = false

    // MARK: Lifecycle

    /// Launch: restores the stored session, then syncs and starts the periodic timer.
    func start() async {
        await auth?.restore()
        restoredSession = true
        await didSignIn()
        startPeriodic()
    }

    func setActive(_ active: Bool) {
        if active {
            startPeriodic()
            Task { await syncNow() }
        } else {
            periodic?.cancel()
            periodic = nil
        }
    }

    /// A local edit happened: count it and sync a moment later (edits in a burst coalesce).
    func localDataChanged() {
        refreshPending()
        guard engine != nil else { return }
        debouncer.schedule { [weak self] in await self?.syncNow() }
    }

    func syncNow() async {
        guard let engine else { return }
        await engine.sync()
        afterRound(engine)
    }

    func resolve(conflict id: UUID, keepLocal: Bool) async {
        guard let engine else { return }
        await engine.resolve(conflict: id, keepLocal: keepLocal)
        afterRound(engine)
    }

    /// The signed-in account differs from the data's owner, and the owner chose to remove the local copy.
    func confirmAccountSwitch() async throws {
        guard accountSwitchPending, let userId = auth?.state.userId else { return }
        try await wipeLocal()
        store.ownerUserId = userId
        accountSwitchPending = false
        settleGymRows(for: userId)
        refreshEngine()
        await syncNow()
    }

    /// Backs out of signing in to a different account: signs out again and keeps the local data.
    func cancelAccountSwitch() async throws {
        accountSwitchPending = false
        await auth?.signOut()
        await dropEngine()
    }

    func remoteWorkout(id: UUID) async -> WorkoutSnapshot? {
        do { return try await engine?.remoteWorkout(id: id) }
        catch {
            Self.log.error("Fetch remote workout failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// When an agent last used the MCP server for this account; nil if never, signed out, or unreachable.
    func lastMcpUse() async -> Date? {
        do { return try await engine?.lastMcpUse() } catch {
            Self.log.error("Read Claude's last use failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The agents connected to this account, newest connection first (Settings › AI agents). Signed out there's no
    /// session to ask with, which isn't the same as no agents (added after review).
    func connectedAgents() async throws -> [ConnectedAgent] {
        guard let engine else { throw SyncUnavailableError() }
        return try await engine.connectedAgents()
    }

    /// Ends one agent's access; the others keep theirs. Signed out there's no session to do it with.
    func disconnectAgent(clientId: String) async throws {
        guard let engine else { throw SyncUnavailableError() }
        try await engine.disconnectAgent(clientId: clientId)
    }

    /// Pushes the profile now (not debounced) and returns once the server stored it. Without a backend or while
    /// signed out there's nowhere to push (the change syncs after signing in); signed in without a running engine
    /// (account switch pending) it throws.
    func pushProfileNow() async throws {
        guard let engine else {
            if isAvailable, authState != .signedOut { throw SyncUnavailableError() }
            return
        }
        defer { afterRound(engine) }
        try await engine.pushProfileNow()
    }

    /// A last sync before signing out; returns what would still be lost (rows not uploaded, rows refused).
    func finalSync() async -> (unsynced: Int, failed: Int) {
        await syncNow()
        refreshPending()
        return (pendingChanges, syncFailures.count)
    }

    /// Revokes Claude's OAuth grant(s) for the signed-in account; 0 when signed out (no session to revoke with).
    func revokeClaudeAccess() async throws -> Int {
        try await engine?.revokeOAuthGrants() ?? 0
    }

    /// The Claude sign-in waiting with `code` (Approve a connection). Signed out there's no session to ask with.
    func connectRequest(code: String) async throws -> ConnectRequest {
        guard let engine else { throw SyncUnavailableError() }
        return try await engine.connectRequest(code: code)
    }

    func decideConnect(code: String, decision: ConnectDecision) async throws {
        guard let engine else { throw SyncUnavailableError() }
        try await engine.decideConnect(code: code, decision: decision)
    }

    // MARK: Account

    #if DEBUG
    func signIn(email: String, password: String) async throws {
        try await auth?.signIn(email: email, password: password)
        await didSignIn()
    }

    func signUp(email: String, password: String) async throws {
        try await auth?.signUp(email: email, password: password)
        await didSignIn()
    }
    #endif

    /// With `waitingForSync` false it returns once the account owns the phone's data, and the first full sync runs
    /// on its own: a sheet asking to share doesn't sit busy through a long first sync of a big history.
    func signInWithApple(idToken: String, nonce: String, waitingForSync: Bool = true) async throws {
        try await auth?.signInWithApple(idToken: idToken, nonce: nonce)
        await didSignIn(waitingForSync: waitingForSync)
    }

    /// Signs out and removes this iPhone's copy of the data (the caller confirms first; the data stays in the
    /// account).
    func signOutAndRemoveLocalData() async throws {
        await onWillSignOut()
        onSessionEnding()
        await auth?.signOut()
        accountSwitchPending = false
        try await wipeLocal()
    }

    // MARK: Private

    /// After sign-in or session restore: checks who owns the local data, then starts syncing (idempotent).
    func didSignIn(waitingForSync: Bool = true) async {
        if let userId = auth?.state.userId {
            switch store.ownerUserId {
            case nil:
                store.ownerUserId = userId // data from before signing in (or none): adopt and upload it
            case userId:
                break
            default:
                if (try? store.hasLocalData()) == false {
                    store.ownerUserId = userId
                } else {
                    accountSwitchPending = true
                    await dropEngine()
                    refreshPending()
                    return
                }
            }
            accountSwitchPending = false
            settleGymRows(for: userId)
        }
        refreshEngine()
        if waitingForSync {
            await firstSync()
        } else {
            Task { await firstSync() }
        }
    }

    private func firstSync() async {
        await syncNow()
        if auth?.state.userId != nil, !accountSwitchPending { onSignedIn() }
    }

    /// Gives the gyms and listings a sign-out left on the phone back to the account they came from, or new ids if
    /// another account signed in. Runs before the first sync, so the pull and the push see settled rows. A failure
    /// is logged: the rows are still "This phone only", so nothing is sent under the wrong account meanwhile.
    private func settleGymRows(for userId: UUID) {
        do {
            let moves = try store.settleDemotedRows(for: userId)
            if !moves.isEmpty { onGymIdsMoved(moves) }
        } catch {
            Self.log.error("Settle gym rows failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// An auth change the app didn't ask for (the SDK's refresh found the session revoked, or refreshed it).
    private func authChangedElsewhere(_ state: AuthState) {
        Task {
            if state == .signedOut {
                onSessionEnding()
                onSessionEnded()
                accountSwitchPending = false
                await dropEngine()
            } else if engine == nil, !accountSwitchPending {
                await didSignIn()
            }
        }
    }

    /// Stops syncing (and waits for a running round to stop) without touching local data.
    func dropEngine() async {
        debouncer.cancel()
        let stopping = engine
        engine = nil
        await stopping?.shutdown()
    }

    /// Stops any running round first, so a late response can't write the old account's rows back.
    /// "This phone only" gyms and anything not yet on the server survive; the rest of the gym data goes (decision 9).
    func wipeLocal(erasingGyms: Bool = false) async throws {
        onSessionEnding()
        onSessionEnded()
        await dropEngine()
        if erasingGyms {
            try store.resetAll()
        } else {
            deleteGymPhotos(try store.resetAccountData())
        }
        pendingChanges = 0
        syncFailures = []
        if erasingGyms { onGymDataErased() }
        onLocalDataReset()
    }

    /// Removes the photo files of gym rows a sign-out dropped (synced and cached shared rows). A file that can't be
    /// removed is logged: the rows are already gone, so it's only wasted space.
    private func deleteGymPhotos(_ files: [String]) {
        for file in files {
            do { try gymPhotoFiles?.delete(file: file) } catch {
                Self.log.error("Delete gym photo failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Creates the engine once signed in (or immediately for a backend without auth) and drops it when signed out.
    func refreshEngine() {
        let signedIn = auth.map { $0.state != .signedOut } ?? true
        if signedIn, !accountSwitchPending, engine == nil, let transport = makeTransport(auth) {
            engine = SyncEngine(store: store, transport: transport, photos: gymPhotoFiles, now: now,
                                autoApply: { [weak self] in try self?.autoApply() ?? 0 })
            seenRemoteChanges = 0
        } else if !signedIn, let stopping = engine {
            engine = nil
            Task { await stopping.shutdown() }
        }
        refreshPending()
    }

    private func afterRound(_ engine: SyncEngine) {
        guard engine === self.engine else { return } // stopped mid-round (sign-out, account switch)
        refreshPending()
        onRoundFinished()
        let moves = store.takeGymMoves()
        if !moves.isEmpty { onGymIdsMoved(moves) }
        guard engine.remoteChangeCount != seenRemoteChanges else { return }
        seenRemoteChanges = engine.remoteChangeCount
        onRemoteChanges()
    }

    private func startPeriodic() {
        periodic?.cancel()
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.periodicInterval) } catch { return }
                await self?.syncNow()
            }
        }
    }

    private func waiting<Value>(_ entity: SyncEntity, _ rows: [SyncRow<Value>], key: (SyncRow<Value>) -> String) -> Int {
        rows.filter { !store.isSyncBlocked(entity, id: key($0), clientUpdatedAt: $0.clientUpdatedAt) }.count
    }

    private func refreshPending() {
        do {
            // Rows the server already refused aren't "waiting": they're listed in `syncFailures` instead.
            pendingChanges = waiting(.profile, try store.dirtyProfile().map { [$0] } ?? [],
                                     key: { _ in SyncStore.profileSyncID })
                + waiting(.customExercises, try store.dirtyCustomExercises(), key: { $0.value.id })
                + waiting(.exercisePreferences, try store.dirtyExercisePreferences(), key: { $0.value.exerciseId })
                + waiting(.routines, try store.dirtyRoutines(), key: { $0.value.routine.id.uuidString })
                + waiting(.weekSchedule, try store.dirtyWeekdays(), key: { String($0.value.weekday) })
                + waiting(.muscleTargets, try store.dirtyMuscleTargets(), key: { $0.value.group.rawValue })
                + waiting(.gyms, try store.dirtyGyms(), key: { $0.value.id.uuidString })
                + waiting(.gymListings, try store.dirtyGymListings(), key: { $0.value.id.uuidString })
                + waiting(.bodyweight, try store.dirtyBodyweight(), key: { $0.value.id.uuidString })
                + waiting(.workouts, try store.dirtyWorkouts(), key: { $0.value.workout.id.uuidString })
            syncFailures = store.syncFailures()
        } catch {
            Self.log.error("Count pending changes failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Signed in, but sync isn't running (e.g. the account switch still needs confirming).
struct SyncUnavailableError: Error {}
