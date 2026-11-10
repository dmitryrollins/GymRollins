import CryptoKit
import Foundation

/// Claude's side of the connection for tests, as claude.ai or Claude Code would run it against the local Worker:
/// registration, PKCE, the authorize step, the `/connect` page in a browser that keeps its own cookies, the token
/// exchange and MCP calls. Plain Foundation, because GymRollinsUITests compiles this file too (project.yml), and
/// the code's approval is the caller's: the app's transport in the integration suites, the sheet in the UI tests.
/// Local only: it talks to `base` and nothing else.
final class ClaudeTestClient: @unchecked Sendable {
    struct Tokens: Sendable {
        let access: String
        let refresh: String
        let scope: String
    }

    /// One sign-in waiting at `/connect`: its code as the page shows it (`XXXX-XXXX`), and what the rest needs.
    struct SignIn: Sendable {
        let code: String
        let clientId: String
        let connectPath: String
        let verifier: String
        let state: String
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let base: URL
    let redirectURI = "http://127.0.0.1:53682/callback"
    private let session: URLSession
    private let lock = NSLock()
    private var cookies: [String: String] = [:]
    private var resource = ""

    init(base: URL) {
        self.base = base
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    // MARK: The flow

    /// Registers a public client with a loopback callback, as Claude Code does; its client_id.
    func register(name: String = "Claude Code") async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "client_name": name, "redirect_uris": [redirectURI], "token_endpoint_auth_method": "none",
        ])
        let (data, status) = try await send("POST", "/api/auth/oauth2/register", body: body,
                                            type: "application/json")
        guard status == 201, let id = try json(data)["client_id"] as? String else {
            throw Failure(description: "registration answered \(status): \(String(decoding: data, as: UTF8.self))")
        }
        return id
    }

    /// The authorize step without a session sends the browser to `/connect`, which shows the code.
    func startSignIn(clientId: String) async throws -> SignIn {
        let resource = try await mcpResource()
        let verifier = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URL
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = UUID().uuidString
        var query = URLComponents()
        query.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "scope", value: "mcp"), .init(name: "resource", value: resource),
        ]
        let (_, status, location) = try await browse("/api/auth/oauth2/authorize?\(query.percentEncodedQuery ?? "")")
        guard status == 302, let connectPath = location, connectPath.hasPrefix("/connect?") else {
            throw Failure(description: "authorize answered \(status), to \(location ?? "nowhere")")
        }
        let (page, _, _) = try await browse(connectPath)
        guard let code = Self.firstMatch(#"class="code">([0-9A-Z]{4}-[0-9A-Z]{4})<"#, in: page) else {
            throw Failure(description: "/connect showed no code: \(page.prefix(300))")
        }
        return SignIn(code: code, clientId: clientId, connectPath: connectPath, verifier: verifier, state: state)
    }

    /// After the approval: the page signs this browser in and re-enters the authorize step, which answers Claude's
    /// callback with a code. Waits up to `timeout` for the decision, checking every second as the page does.
    func finish(_ signIn: SignIn, timeout: Duration = .seconds(30)) async throws -> String {
        let back = try await waitForDecision(signIn, timeout: timeout)
        guard back.hasPrefix("/api/auth/oauth2/authorize?") else {
            throw Failure(description: "the page went to \(back), not back into authorize")
        }
        let (_, status, location) = try await browse(back)
        guard status == 302, let location, let callback = URLComponents(string: location),
              location.hasPrefix(redirectURI), callback.queryItems?.first(where: { $0.name == "state" })?.value
                == signIn.state,
              let code = callback.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw Failure(description: "authorize answered \(status), to \(location ?? "nowhere")")
        }
        return code
    }

    /// After a denial: where the page sends the browser (Claude's callback with `error=access_denied`).
    func denial(_ signIn: SignIn, timeout: Duration = .seconds(30)) async throws -> URLComponents {
        let back = try await waitForDecision(signIn, timeout: timeout)
        guard let url = URLComponents(string: back), back.hasPrefix(redirectURI) else {
            throw Failure(description: "the page went to \(back), not to Claude's callback")
        }
        return url
    }

    func exchange(_ signIn: SignIn, code: String) async throws -> Tokens {
        let (data, status) = try await token([
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": signIn.clientId, "code_verifier": signIn.verifier, "resource": try await mcpResource(),
        ])
        let answer = try json(data)
        guard status == 200, let access = answer["access_token"] as? String,
              let refresh = answer["refresh_token"] as? String else {
            throw Failure(description: "token answered \(status): \(String(decoding: data, as: UTF8.self))")
        }
        return Tokens(access: access, refresh: refresh, scope: answer["scope"] as? String ?? "")
    }

    /// The token endpoint's status for a refresh: 200 while the grant lives.
    func refreshStatus(clientId: String, refreshToken: String) async throws -> Int {
        try await token([
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId,
            "resource": try await mcpResource(),
        ]).status
    }

    /// Registration, the sign-in, `approve(code)`, and the tokens: a connected Claude in one call.
    func connect(approve: @Sendable (String) async throws -> Void) async throws -> Tokens {
        let signIn = try await startSignIn(clientId: try await register())
        try await approve(signIn.code)
        return try await exchange(signIn, code: try await finish(signIn))
    }

    // MARK: MCP

    /// A JSON-RPC call to `/mcp`: the HTTP status, and the answer's `result` when there is one.
    func mcp(_ accessToken: String, method: String, params: [String: Any] = [:]) async throws
        -> (status: Int, result: [String: Any]?) {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ])
        var request = URLRequest(url: base.appending(path: "/mcp"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        let message = text.split(separator: "\n").last { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)) } ?? text
        let answer = (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any]
        return (status, answer?["result"] as? [String: Any])
    }

    /// A tool's JSON answer (the text content parsed), and whether the tool reported an error.
    func callTool(_ accessToken: String, _ name: String, _ arguments: [String: Any] = [:]) async throws
        -> (isError: Bool, json: [String: Any]) {
        let (status, result) = try await mcp(accessToken, method: "tools/call",
                                             params: ["name": name, "arguments": arguments])
        guard status == 200, let result, let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw Failure(description: "tools/call \(name) answered \(status)")
        }
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return (result["isError"] as? Bool ?? false, json)
    }

    // MARK: HTTP

    /// The MCP resource, as the server's RFC 9728 document names it.
    private func mcpResource() async throws -> String {
        if let known = lock.withLock({ resource.isEmpty ? nil : resource }) { return known }
        let (data, _) = try await send("GET", "/.well-known/oauth-protected-resource/mcp")
        guard let named = try json(data)["resource"] as? String else { throw Failure(description: "no resource") }
        lock.withLock { resource = named }
        return named
    }

    /// The page's meta refresh target once the request is decided; nil while it still waits (a plain reload).
    private func waitForDecision(_ signIn: SignIn, timeout: Duration) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let (page, status, _) = try await browse(signIn.connectPath)
            if let target = Self.firstMatch(#"http-equiv="refresh" content="\d+;url=([^"]+)""#, in: page) {
                return target.replacingOccurrences(of: "&amp;", with: "&")
            }
            guard status == 200 else { throw Failure(description: "/connect answered \(status)") }
            try await Task.sleep(for: .seconds(1))
        }
        throw Failure(description: "no decision within \(timeout)")
    }

    /// A browser's GET: its cookies sent, the answer's cookies kept, no redirect followed.
    private func browse(_ path: String) async throws -> (page: String, status: Int, location: String?) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let jar = lock.withLock { cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ") }
        if !jar.isEmpty { request.setValue(jar, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let url = http.url else { throw URLError(.badServerResponse) }
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            lock.withLock {
                if cookie.value.isEmpty || (cookie.expiresDate.map { $0 <= Date() } ?? false) {
                    cookies[cookie.name] = nil
                } else {
                    cookies[cookie.name] = cookie.value
                }
            }
        }
        return (String(decoding: data, as: UTF8.self), http.statusCode, http.value(forHTTPHeaderField: "Location"))
    }

    private func token(_ form: [String: String]) async throws -> (data: Data, status: Int) {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        return try await send("POST", "/api/auth/oauth2/token", body: Data(body.utf8),
                              type: "application/x-www-form-urlencoded")
    }

    private func send(_ method: String, _ path: String, body: Data? = nil,
                      type: String? = nil) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Hands every 3xx back instead of following it, so each step of the flow can be checked.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
