import Foundation
import GymCore

/// Where a workout link points. With no host the app makes `gymrollins://w#…`, and with one `https://<host>/w#…`. It reads
/// both, so links sent before the domain existed keep working. The workout sits after the `#`, which browsers don't send
/// to the website.
struct WorkoutLink: Equatable {
    static let scheme = "gymrollins"
    private static let appLinkHost = "w"

    let host: String?

    init(host: String?) {
        let trimmed = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.host = trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    /// This build's link, from `SHARE_LINK_HOST` in `Config/Base.xcconfig`.
    static var configured: WorkoutLink {
        WorkoutLink(host: Bundle.main.object(forInfoDictionaryKey: "SHARE_LINK_HOST") as? String)
    }

    func url(for workout: SharedWorkout) -> URL? {
        let start = host.map { "https://\($0)/w" } ?? "\(Self.scheme)://\(Self.appLinkHost)"
        return URL(string: "\(start)#\(workout.linkText)")
    }

    /// The text after the `#`, or nil when `url` isn't a workout link this build accepts.
    func payload(in url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.port == nil, parts.query == nil,
              let fragment = parts.percentEncodedFragment, !fragment.isEmpty else { return nil }
        switch parts.scheme?.lowercased() {
        case Self.scheme:
            return parts.host == Self.appLinkHost && parts.path.isEmpty ? fragment : nil
        case "https":
            guard let host, parts.host?.lowercased() == host, parts.path == "/w" || parts.path == "/w/" else { return nil }
            return fragment
        default:
            return nil
        }
    }
}
