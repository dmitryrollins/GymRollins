import Foundation
import GymData
import Testing
@testable import GymSync

/// What the gym suites share on the Worker.
extension Account {
    /// The shared catalogue, moderation and shared photos, as this account's phone reaches them.
    var catalog: ApiGymCatalogTransport { ApiGymCatalogTransport(api: auth.api) }
}

enum GymIntegration {
    /// A JPEG as far as the server checks one (its first bytes, and the declared type), at a photo-like size.
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 596)

    /// A phone with no account: the catalogue answers it `.signedOut`, reads included (spec section 3).
    static func signedOutCatalog() throws -> ApiGymCatalogTransport {
        ApiGymCatalogTransport(api: try IntegrationEnv.config().makeClient(sessions: InMemorySessionStore()))
    }

    static func signedOutTransport() throws -> ApiSyncTransport {
        ApiSyncTransport(api: try IntegrationEnv.config().makeClient(sessions: InMemorySessionStore()))
    }

    /// Whether `/photos/shared/<name>` serves the photo to anyone, past every cache.
    static func isServed(_ name: String) async throws -> Bool {
        let url = try #require(try signedOutCatalog().publicPhotoURL(path: name))
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
