import Foundation

/// A Claude sign-in waiting for the owner, as Settings › Claude › Approve a connection shows it: what the browser's
/// `/connect` page asked for, looked up by the code it shows (`GET /v1/claude/connect/:code`, spec section 4,
/// "Claude's connection").
public struct ConnectRequest: Decodable, Equatable, Sendable {
    /// The code as the page shows it, `XXXX-XXXX`.
    public let code: String
    /// The name the client registered with ("Claude", "Claude Code"); nil when it gave none.
    public let clientName: String?
    /// Where an approval sends the browser back to: `claude.ai`, or `127.0.0.1:<port>` for Claude Code.
    public let redirectHost: String
    /// True for Claude's own hosts (claude.ai, claude.com). For any other, the sheet warns before Approve.
    public let knownHost: Bool
    public let expiresAt: Date
    /// Added after review: when the browser opened the page that shows the code.
    public let openedAt: Date
    /// Added after review: where it was opened, as Cloudflare saw it: a country code ("CA") and a city. Nil when
    /// unknown, as both always are against a local Worker.
    public let country: String?
    public let city: String?
    /// Added after review: the opening browser's User-Agent (at most 256 characters); nil when it sent none.
    public let userAgent: String?

    public init(code: String, clientName: String?, redirectHost: String, knownHost: Bool, expiresAt: Date,
                openedAt: Date, country: String? = nil, city: String? = nil, userAgent: String? = nil) {
        self.code = code
        self.clientName = clientName
        self.redirectHost = redirectHost
        self.knownHost = knownHost
        self.expiresAt = expiresAt
        self.openedAt = openedAt
        self.country = country
        self.city = city
        self.userAgent = userAgent
    }

    enum CodingKeys: String, CodingKey {
        case code, clientName = "client_name", redirectHost = "redirect_host", knownHost = "known_host"
        case expiresAt = "expires_at", openedAt = "opened_at", country, city, userAgent = "user_agent"
    }
}

public enum ConnectDecision: String, Sendable {
    case approve, deny
}

/// Why a typed code couldn't be used.
public enum ConnectCodeError: Error, Equatable, Sendable {
    /// No sign-in is waiting with this code: mistyped, expired or already decided (404 `unknown_code`).
    case unknownCode
    /// Five wrong codes in 10 minutes; even a right one waits (429 `too_many_attempts`).
    case tooManyAttempts
}

/// The approval code as the owner types it (spec section 5): 8 characters of Crockford's alphabet (no I, L, O or U),
/// case-insensitive, shown as `XXXX-XXXX`. O, I and L read as 0, 1 and 1, as the server reads them.
public enum ConnectCode {
    public static let length = 8
    private static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// What the owner typed, as at most `length` code characters: upper case, O/I/L as 0/1/1, anything else dropped.
    public static func characters(of typed: String) -> String {
        let read = typed.uppercased().map { (ch: Character) -> Character in
            switch ch {
            case "O": "0"
            case "I", "L": "1"
            default: ch
            }
        }
        return String(read.filter { alphabet.contains($0) }.prefix(length))
    }

    /// The code as typed so far, with the dash after the fourth character: "AB", "ABCD-E", "ABCD-EFGH".
    public static func display(_ typed: String) -> String {
        let code = characters(of: typed)
        guard code.count > 4 else { return code }
        return "\(code.prefix(4))-\(code.dropFirst(4))"
    }

    /// The 8 characters once all are typed, else nil.
    public static func complete(_ typed: String) -> String? {
        let code = characters(of: typed)
        return code.count == length ? code : nil
    }
}
