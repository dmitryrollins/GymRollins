import Foundation

/// An error answer from the GymRollins API: the HTTP status and the `{"error": {"code", "message"}}` body every error
/// carries (server/src/http/errors.ts). The codes keep the strings the app knew from Postgres (`row_rejected`,
/// `not_allowed`, `photos_remain`, …); Better Auth's arrive lowercased (`invalid_email_or_password`, …).
public struct ApiError: LocalizedError, Equatable, Sendable {
    public let status: Int
    public let code: String
    public let message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    /// A busy or rate-limited server (5xx, 429): nothing is wrong with the request, so the app tries again later.
    public var isTemporary: Bool { status == 429 || (500...599).contains(status) }

    /// Network failures (a cancelled request included), rate limits and server errors: what the app shows as offline
    /// and tries again. A URL the app built wrong is a bug, not the network, so it isn't one.
    public static func isOffline(_ error: Error) -> Bool {
        if let api = error as? ApiError { return api.isTemporary }
        let failure = error as NSError
        return failure.domain == NSURLErrorDomain && !malformed.contains(failure.code)
    }

    /// `URLError.badURL` and `.unsupportedURL`: trying again sends the same broken request.
    private static let malformed: Set<Int> = [NSURLErrorBadURL, NSURLErrorUnsupportedURL]

    /// Reads an error answer. A body in another shape (a proxy's HTML page, an empty 502) still gives the status, with
    /// the code `http_<status>`.
    static func from(status: Int, body: Data) -> ApiError {
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: body) {
            return ApiError(status: status, code: envelope.error.code, message: envelope.error.message)
        }
        return ApiError(status: status, code: "http_\(status)",
                        message: HTTPURLResponse.localizedString(forStatusCode: status))
    }

    private struct Envelope: Decodable {
        struct Body: Decodable {
            let code: String
            let message: String
        }

        let error: Body
    }
}
