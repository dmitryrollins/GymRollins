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
/// case-insensitive, shown as `XXXX-XXXX`. O, I and L read as 0, 1 and 1, and spaces and hyphens don't matter, as the
/// server's `normalizeCode` reads them (server/src/claude/connect-code.ts).
public enum ConnectCode {
    public static let length = 8
    private static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// What the owner typed, as code characters: upper case, O/I/L as 0/1/1, spaces and hyphens left out. Nil when
    /// anything else is there. Added after review: such a character used to be dropped, so "Code: ABCD-EFGH" was
    /// sent as C0DEABCD and used a try, and `ß` upper-cased to "SS".
    public static func characters(of typed: String) -> String? {
        var code = ""
        for ch in typed where !(ch.isWhitespace || ch == "-") {
            guard ch.isASCII, let read = read(ch) else { return nil }
            code.append(read)
        }
        return code
    }

    /// One ASCII character as a code character, or nil.
    private static func read(_ ch: Character) -> Character? {
        let upper = Character(ch.uppercased())
        let read: Character = switch upper {
        case "O": "0"
        case "I", "L": "1"
        default: upper
        }
        return alphabet.contains(read) ? read : nil
    }

    /// The code as typed so far, with the dash after the fourth character: "AB", "ABCD-E", "ABCD-EFGH". Text that is
    /// no code is shown as typed, so the owner sees what to fix.
    public static func display(_ typed: String) -> String {
        guard let code = characters(of: typed) else { return typed }
        guard code.count > 4 else { return code }
        return "\(code.prefix(4))-\(code.dropFirst(4))"
    }

    /// The 8 characters once exactly those are typed, else nil: the only text the sheet sends.
    public static func complete(_ typed: String) -> String? {
        guard let code = characters(of: typed), code.count == length else { return nil }
        return code
    }

    /// Added after review: true when the text can't become a code by typing more (a character outside the alphabet,
    /// or more than 8), so the sheet says so instead of waiting.
    public static func isInvalid(_ typed: String) -> Bool {
        guard let code = characters(of: typed) else { return true }
        return code.count > length
    }
}
