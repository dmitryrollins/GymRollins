import Foundation
import GymSync
import Observation

/// What Approve a connection does (spec section 5), apart from how it looks: the typed code shown as `XXXX-XXXX`, the
/// lookup once all 8 characters are in, then the owner's decision. The calls are injected, so tests run it without a
/// server (`ApproveConnectionModelTests`); the app passes the sync coordinator's.
@MainActor @Observable
final class ApproveConnectionModel {
    enum Phase: Equatable {
        case typing
        case lookingUp
        case found(ConnectRequest)
        case deciding(ConnectRequest)
        case approved
        case denied
    }

    typealias LookUp = @MainActor (String) async throws -> ConnectRequest
    typealias Decide = @MainActor (String, ConnectDecision) async throws -> Void

    private(set) var typed = ""
    private(set) var phase: Phase = .typing
    private(set) var error: String?
    @ObservationIgnored private let lookUpCall: LookUp
    @ObservationIgnored private let decideCall: Decide
    /// The code last refused: it isn't sent again until the owner changes it (each wrong one uses a try).
    @ObservationIgnored private var refused: String?

    init(lookUp: @escaping LookUp, decide: @escaping Decide) {
        lookUpCall = lookUp
        decideCall = decide
    }

    /// All 8 characters, once typed: what the view looks up.
    var complete: String? { ConnectCode.complete(typed) }

    /// The request being decided on, while there is one.
    var request: ConnectRequest? {
        switch phase {
        case .found(let request), .deciding(let request): request
        default: nil
        }
    }

    var isDone: Bool { phase == .approved || phase == .denied }

    /// Added after review: the field takes typing until a decision is sent. Changing a found code starts over, and so
    /// does a code changed during its lookup (which cancels it); a decision on its way or made keeps the field.
    var canEditCode: Bool {
        switch phase {
        case .typing, .lookingUp, .found: true
        case .deciding, .approved, .denied: false
        }
    }

    /// Added after review: the field holds text that can't become a code (a character outside the alphabet, or more
    /// than 8). It is never sent, and the sheet says why.
    var isInvalid: Bool { ConnectCode.isInvalid(typed) }

    static let notACode = "That isn't a code. Claude's page shows 8 letters and digits, like 7K2M-9PQR."

    /// The field's new text: code characters with the dash (other text as typed), and a changed code starts over.
    func type(_ text: String) {
        guard canEditCode else { return }
        let shown = ConnectCode.display(text)
        guard shown != typed else { return }
        typed = shown
        phase = .typing
        error = nil
    }

    /// Looks the complete code up once. A wrong one stays in the field with the reason; changing it tries again.
    /// Added after review: only a code the server doesn't know is refused for good. After any other failure
    /// (offline, 5xx, signed out, too many tries) retyping the same code sends it again. A lookup cancelled because
    /// the code changed (the view's task follows it) writes nothing: it is no answer, and no refusal.
    func lookUp() async {
        guard let code = complete, phase == .typing, code != refused else { return }
        phase = .lookingUp
        do {
            let found = try await lookUpCall(code)
            if Task.isCancelled { return }
            guard complete == code else { return } // retyped meanwhile
            phase = .found(found)
        } catch {
            if Task.isCancelled { return }
            guard complete == code else { return }
            phase = .typing
            if case ConnectCodeError.unknownCode = error { refused = code }
            self.error = Self.message(for: error)
        }
    }

    /// Approve or Deny the request shown. Added after review: it sends that request's own code, and writes its outcome
    /// only while that decision is still the phase. When the code has died (expired or decided while the sheet was
    /// open) or the tries are used up, the sheet goes back to the field and that code isn't sent again, so Approve
    /// can't use more tries; any other failure keeps the request, to try again.
    func decide(_ decision: ConnectDecision) async {
        guard case .found(let request) = phase, let code = ConnectCode.complete(request.code) else { return }
        phase = .deciding(request)
        error = nil
        do {
            try await decideCall(code, decision)
            guard phase == .deciding(request) else { return }
            phase = decision == .approve ? .approved : .denied
        } catch {
            guard phase == .deciding(request) else { return }
            self.error = Self.message(for: error)
            switch error {
            case ConnectCodeError.unknownCode, ConnectCodeError.tooManyAttempts:
                phase = .typing
                refused = code
            default:
                phase = .found(request)
            }
        }
    }

    static let signInFirst = "Sign in to GymRollins first, with the account Claude should use."

    /// Added after the server's whole-flow review: shown under every request, whatever its host. Someone can add
    /// this server to their own claude.ai account (host `claude.ai`, no warning) and ask the owner to type the code.
    static let caution = "Approve only a code that's on your own screen, from a connection you started just now."

    /// Plan 32: for a host that isn't Claude's own (claude.ai, claude.com), a warning that names it, worded for any
    /// agent; none for Claude's.
    static func hostWarning(for request: ConnectRequest) -> String? {
        request.knownHost ? nil : "Approve only if you started this connection yourself, in \(request.redirectHost)."
    }

    /// Added after review: "Opened 2 min ago · Toronto, CA · Safari", leaving out what the server doesn't know.
    /// A code lasts 10 minutes, so minutes are enough; a phone clock behind the server's reads "just now".
    static func openedLine(for request: ConnectRequest, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(request.openedAt) / 60)
        let when = minutes < 1 ? "Opened just now" : "Opened \(minutes) min ago"
        let place = [request.city, request.country].compactMap { $0 }.joined(separator: ", ")
        let browser = request.userAgent.map(browserName)
        return [when, place, browser ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    /// The browser a User-Agent names, most specific first (Edge's and Chrome's also say Safari); else its first
    /// product name ("curl", "node"), at most 24 characters.
    static func browserName(_ userAgent: String) -> String {
        let known: [(name: String, markers: [String])] = [
            ("Edge", ["Edg/", "EdgiOS/", "EdgA/"]), ("Opera", ["OPR/", "OPT/"]), ("Firefox", ["Firefox/", "FxiOS/"]),
            ("Chrome", ["CriOS/", "Chrome/"]), ("Safari", ["Safari/"]),
        ]
        if let match = known.first(where: { entry in entry.markers.contains { userAgent.contains($0) } }) {
            return match.name
        }
        return String(userAgent.prefix { $0 != "/" && $0 != " " }.prefix(24))
    }

    static func message(for error: Error) -> String {
        switch error {
        case ConnectCodeError.unknownCode:
            "No sign-in is waiting with this code. Check it, or start again from Claude: a code lasts 10 minutes "
                + "and works once."
        case ConnectCodeError.tooManyAttempts:
            "Too many wrong codes. Try again in 10 minutes."
        case is SyncUnavailableError:
            signInFirst
        case let api as ApiError where api.status == 401:
            signInFirst
        default:
            ApiError.isOffline(error)
                ? "Couldn't reach GymRollins. Check your connection and try again."
                : "Couldn't check this code. Try again."
        }
    }
}
