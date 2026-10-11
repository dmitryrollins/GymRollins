import Foundation
import GymData
import GymSync
import Supabase

extension SyncCoordinator {
    /// Builds the coordinator for the launch's `SyncBackend`. A missing or invalid Supabase config disables sync
    /// (logged) instead of failing the launch: the app works fully offline.
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
            guard let config = config(options) else {
                return SyncCoordinator(auth: nil, store: store, now: now, makeTransport: { _ in nil })
            }
            let auth = AuthService(client: config.makeClient(storage: authStorage(options)))
            let offline = options.simulateOffline
            return SyncCoordinator(auth: auth, store: store, now: now, makeTransport: { auth in
                guard let auth else { return nil }
                #if DEBUG
                if offline { return OfflineTransport() }
                #endif
                return SupabaseTransport(client: auth.client)
            })
        }
    }

    /// The MCP connector URL Claude needs (`<SUPABASE_URL>/functions/v1/mcp`), nil without a Supabase config.
    static func connectorURL(options: LaunchOptions) -> String? {
        config(options).map { $0.url.appending(path: "functions/v1/mcp").absoluteString }
    }

    private static func config(_ options: LaunchOptions) -> SupabaseConfig? {
        #if DEBUG
        if let fromEnvironment = try? SupabaseConfig(environment: options.environment) { return fromEnvironment }
        #endif
        do { return try SupabaseConfig.fromBundle() }
        catch {
            log.error("Sync disabled, bad Supabase config: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func authStorage(_ options: LaunchOptions) -> (any AuthLocalStorage)? {
        #if DEBUG
        if options.syncBackend == .uiTestLocal {
            if options.resetStore || options.forgetSession { UITestAuthStorage.wipe() }
            return UITestAuthStorage()
        }
        #endif
        return nil // the SDK's Keychain storage
    }
}
