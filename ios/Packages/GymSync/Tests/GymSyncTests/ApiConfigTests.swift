import Foundation
import Testing
@testable import GymSync

/// `API_URL` from Info.plist or the environment, and the origin the server move compares.
@Suite struct ApiConfigTests {
    @Test func readsTheOriginFromInfo() throws {
        let config = try ApiConfig(info: ["API_URL": "http://127.0.0.1:8787"])
        #expect(config.baseURL == URL(string: "http://127.0.0.1:8787"))
        #expect(config.origin == "http://127.0.0.1:8787")
    }

    @Test func oneAPIHasOneOrigin() throws {
        for raw in ["https://GymRollins.Example.workers.dev", "https://gymrollins.example.workers.dev/",
                    "https://gymrollins.example.workers.dev:443", " https://gymrollins.example.workers.dev "] {
            #expect(try ApiConfig(info: ["API_URL": raw]).origin == "https://gymrollins.example.workers.dev")
        }
        #expect(try ApiConfig(info: ["API_URL": "http://127.0.0.1:55421"]).origin
            != ApiConfig(info: ["API_URL": "http://127.0.0.1:8787"]).origin, "the port tells the local servers apart")
    }

    @Test func rejectsAMissingOrEmptyURL() {
        #expect(throws: ApiConfigError.missing) { try ApiConfig(info: [:]) }
        #expect(throws: ApiConfigError.missing) { try ApiConfig(info: ["API_URL": "  "]) }
    }

    @Test func rejectsAnythingButAnHTTPOrigin() {
        // `http:/$()/host` in an xcconfig expands to `http://host`; an unexpanded build setting must not slip through.
        for raw in ["$(API_URL)", "127.0.0.1:8787", "ftp://example.com", "http://", "http://127.0.0.1:1@evil.example/",
                    "https://example.com/api", "https://example.com/?a=1", "https://example.com/#x"] {
            #expect(throws: ApiConfigError.invalidURL(raw)) { try ApiConfig(info: ["API_URL": raw]) }
        }
    }

    @Test func readsTheEnvironment() throws {
        #expect(try ApiConfig(environment: ["API_URL": "http://localhost:8788"]).origin == "http://localhost:8788")
    }
}
