import Foundation
import Testing
@testable import GymSync

@Suite struct SupabaseConfigTests {
    @Test func readsInfoDictionary() throws {
        let config = try SupabaseConfig(info: ["SUPABASE_URL": "http://127.0.0.1:55421", "SUPABASE_ANON_KEY": "anon"])
        #expect(config.url == URL(string: "http://127.0.0.1:55421"))
        #expect(config.anonKey == "anon")
    }

    @Test func rejectsMissingOrEmptyKeys() {
        #expect(throws: SupabaseConfigError.missing("SUPABASE_URL")) {
            try SupabaseConfig(info: ["SUPABASE_ANON_KEY": "anon"])
        }
        #expect(throws: SupabaseConfigError.missing("SUPABASE_ANON_KEY")) {
            try SupabaseConfig(info: ["SUPABASE_URL": "http://127.0.0.1:55421", "SUPABASE_ANON_KEY": "  "])
        }
    }

    @Test func rejectsUnexpandedOrSchemelessURLs() {
        // `http:/$()/host` in an xcconfig expands to `http://host`; an unexpanded build setting must not slip through.
        for raw in ["$(SUPABASE_URL)", "127.0.0.1:55421", "ftp://example.com", "http://"] {
            #expect(throws: SupabaseConfigError.invalidURL(raw)) {
                try SupabaseConfig(info: ["SUPABASE_URL": raw, "SUPABASE_ANON_KEY": "anon"])
            }
        }
    }

    @Test func readsEnvironment() throws {
        let config = try SupabaseConfig(environment: ["SUPABASE_URL": "https://abc.supabase.co",
                                                      "SUPABASE_ANON_KEY": "key"])
        #expect(config.url.host() == "abc.supabase.co")
    }

    @Test func inMemoryStorageRoundTrips() throws {
        let storage = InMemoryAuthStorage()
        try storage.store(key: "k", value: Data([1, 2]))
        #expect(try storage.retrieve(key: "k") == Data([1, 2]))
        try storage.remove(key: "k")
        #expect(try storage.retrieve(key: "k") == nil)
    }
}

