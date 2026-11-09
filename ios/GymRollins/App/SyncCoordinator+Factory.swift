import Foundation
import GymData
import GymSync

extension SyncCoordinator {
    /// Builds the coordinator for the launch's `SyncBackend`. A missing or invalid `API_URL` disables sync (logged)
    /// instead of failing the launch: the app works fully offline. Before anything signs in, the data moves to this API
    /// if it last synced with another one (`SyncStore.moveToServer`, spec section 4 "Server move").
    static func make(options: LaunchOptions, store: SyncStore, now: @escaping () -> Date) -> SyncCoordinator {
        switch options.syncBackend {
        case .disabled:
            return SyncCoordinator(auth: nil, store: store, now: now, makeTransport: { _ in nil })
        case .seededConflict:
            #if DEBUG
            let fake = SeededConflictTransport()
            return SyncCoordinator(auth: nil, store: store, now: now, makeTransport: { _ in fake })
            #else
            return SyncCoordinator(auth: nil, store: store, now: now, makeTransport: { _ in nil })
            #endif
        case .configured, .uiTestLocal:
            guard let config = apiConfig(options) else {
                return SyncCoordinator(auth: nil, store: store, now: now, makeTransport: { _ in nil })
            }
            let sessions = sessionStore(options)
            guard moveIfNeeded(store, to: config, sessions: sessions) else {
                return SyncCoordinator(auth: nil, store: store, now: now, makeTransport: { _ in nil })
            }
            let auth = AuthService(api: config.makeClient(sessions: sessions))
            let offline = options.simulateOffline
            return SyncCoordinator(auth: auth, store: store, now: now, makeTransport: { auth in
                guard let auth else { return nil }
                #if DEBUG
                if offline { return OfflineTransport() }
                #endif
                return ApiSyncTransport(api: auth.api)
            })
        }
    }

    /// The server move, before the session is restored. False when it failed: sync stays off for this launch, because
    /// data still marked as the old server's must not meet a new account (the account-switch prompt would offer to
    /// remove it). The next launch tries again.
    private static func moveIfNeeded(_ store: SyncStore, to config: ApiConfig, sessions: any SessionStore) -> Bool {
        do {
            // The catalogue has its own marker: it may come from another server although the account's marker matches.
            if try store.forgetCatalogueOfOtherServer(config.origin) {
                log.notice("Forgot the shared catalogue cached from another server")
            }
            if try store.moveToServer(config.origin) {
                sessions.clear() // a session the old server gave means nothing here
                log.notice("Moved this phone's data to \(config.origin, privacy: .public); it uploads after the next sign-in")
            }
            return true
        } catch {
            log.error("Server move failed, sync off for this launch: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The MCP connector URL Claude needs, `<API_URL>/mcp` (spec section 5); nil without an API.
    static func connectorURL(options: LaunchOptions) -> String? {
        apiConfig(options).map { $0.baseURL.appending(path: "mcp").absoluteString }
    }

    private static func apiConfig(_ options: LaunchOptions) -> ApiConfig? {
        #if DEBUG
        if let fromEnvironment = try? ApiConfig(environment: options.environment) { return fromEnvironment }
        #endif
        do { return try ApiConfig.fromBundle() }
        catch {
            log.error("Sync disabled, bad API_URL: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func sessionStore(_ options: LaunchOptions) -> any SessionStore {
        #if DEBUG
        if options.syncBackend == .uiTestLocal {
            if options.resetStore || options.forgetSession { UITestSessionStore.wipe() }
            return UITestSessionStore()
        }
        #endif
        return KeychainSessionStore()
    }
}
