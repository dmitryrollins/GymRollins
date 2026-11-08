import CryptoKit
import Foundation
import Supabase
import Testing
@testable import GymSync

/// "Disconnect Claude" against the real local Auth server: a throwaway OAuth client (DCR) gets a real grant through
/// authorize → consent approve → PKCE code exchange, then `revokeOAuthGrants()` removes it and the client can no
/// longer refresh its token.
@MainActor
@Suite(.enabled(if: supabaseConfigured, "Set SUPABASE_URL and SUPABASE_ANON_KEY to run against local Supabase"))
struct OAuthGrantTransportTests {
    @Test func revokeRemovesTheGrantAndItsRefreshToken() async throws {
        let user = try await Account.signUp()
        let transport = user.transport
        #expect(try await transport.revokeOAuthGrants() == 0) // nothing granted yet

        let flow = try OAuthFlow(config: try IntegrationEnv.config())
        let clientId = try await flow.register()
        let authorizationId = try await flow.authorize(clientId: clientId)
        let oauth = user.auth.client.auth.oauthServer
        _ = try await oauth.getAuthorizationDetails(authorizationId: authorizationId) // what the consent page shows
        let redirect = try await oauth.approveAuthorization(authorizationId: authorizationId)
        let code = try #require(URLComponents(string: redirect.redirectURL.absoluteString)?.queryItems?
            .first { $0.name == "code" }?.value)
        let refreshToken = try await flow.exchange(code: code, clientId: clientId)

        let grants = try await user.auth.client.auth.oauthServer.listGrants()
        #expect(grants.map { $0.client.id.uuidString.lowercased() } == [clientId.lowercased()])
        #expect(try await transport.revokeOAuthGrants() == 1)
        #expect(try await user.auth.client.auth.oauthServer.listGrants().isEmpty)
        let status = try await flow.refreshStatus(refreshToken: refreshToken, clientId: clientId)
        #expect((400..<500).contains(status), "refresh after revoke answered HTTP \(status)")

        try await user.deleteAccount()
    }
}

/// The OAuth client side of the flow (what Claude does), over plain HTTP.
private struct OAuthFlow {
    let base: URL
    let anonKey: String
    let verifier = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
    let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    init(config: SupabaseConfig) throws {
        base = config.url.appendingPathComponent("auth/v1")
        anonKey = config.anonKey
    }

    private var challenge: String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, form: Bool = false) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.httpBody = body
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue(form ? "application/x-www-form-urlencoded" : "application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    func register() async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "client_name": "gymsync-it-\(UUID().uuidString.prefix(8))", "redirect_uris": [callbackURI],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, _) = try await session.data(for: request("oauth/clients/register", method: "POST", body: body))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(json?["client_id"] as? String)
    }

    /// The authorize redirect (not followed) carries the `authorization_id` the consent page would use.
    func authorize(clientId: String) async throws -> String {
        var url = URLComponents(url: base.appendingPathComponent("oauth/authorize"), resolvingAgainstBaseURL: false)!
        url.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: callbackURI),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "scope", value: "email profile"), .init(name: "state", value: "it"),
        ]
        var req = URLRequest(url: url.url!)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        let (_, response) = try await session.data(for: req)
        let location = try #require((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"))
        return try #require(URLComponents(string: location)?.queryItems?.first { $0.name == "authorization_id" }?.value)
    }

    func exchange(code: String, clientId: String) async throws -> String {
        let (data, _) = try await session.data(for: tokenRequest([
            "grant_type": "authorization_code", "code": code, "redirect_uri": callbackURI,
            "client_id": clientId, "code_verifier": verifier,
        ]))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(json?["refresh_token"] as? String)
    }

    func refreshStatus(refreshToken: String, clientId: String) async throws -> Int {
        let (_, response) = try await session.data(for: tokenRequest([
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId,
        ]))
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func tokenRequest(_ fields: [String: String]) -> URLRequest {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        return request("oauth/token", method: "POST", body: Data(body.utf8), form: true)
    }
}

private let callbackURI = "http://127.0.0.1:8976/cb"

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
