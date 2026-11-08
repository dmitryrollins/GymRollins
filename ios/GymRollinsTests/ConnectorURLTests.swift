import Testing
@testable import GymRollins

/// The connector address Settings › Claude shows (spec section 5): the API the app syncs with, plus `/mcp`.
@MainActor @Suite struct ConnectorURLTests {
    @Test func theConnectorIsTheAPIsMcp() {
        let options = LaunchOptions(arguments: [], environment: ["API_URL": "http://127.0.0.1:8788"])
        #expect(SyncCoordinator.connectorURL(options: options) == "http://127.0.0.1:8788/mcp")
    }
}
