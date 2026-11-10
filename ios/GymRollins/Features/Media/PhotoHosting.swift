import Foundation
import GymSync

/// Where GymRollins' own photos come from, set per build with `PHOTO_HOSTING` (xcconfig -> Info.plist):
/// - `bundle` (default): only the photos bundled in Resources/OwnPhotos.
/// - `storage`: the public `exercise-photos` bucket behind the API (`<API_URL>/photos/exercises/`, manifest-driven),
///   with the bundled photos as fallback. See docs/media/README.md ("Hosting").
enum PhotoHosting: String, Sendable, Equatable {
    case bundle
    case storage

    static let infoKey = "PHOTO_HOSTING"

    /// Missing, empty or unknown values mean `bundle` (the pre-hosting behaviour).
    init(rawSetting: String?) {
        let value = rawSetting?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = PhotoHosting(rawValue: value) ?? .bundle
    }
}

/// The photo hosting settings for this launch.
struct PhotoHostingConfig: Sendable, Equatable {
    let hosting: PhotoHosting
    /// The API's origin (`ApiConfig`); nil when the build has no valid `API_URL`.
    let apiURL: URL?

    /// From Info.plist; in DEBUG, the `PHOTO_HOSTING` and `API_URL` environment variables win (as for sync), so tests
    /// and debug runs can point at a local Worker.
    static func resolve(info: [String: Any], environment: [String: String]) -> PhotoHostingConfig {
        var hostingSetting = info[PhotoHosting.infoKey] as? String
        var apiURL = (try? ApiConfig(info: info))?.baseURL
        #if DEBUG
        if let override = environment[PhotoHosting.infoKey] { hostingSetting = override }
        if let fromEnvironment = try? ApiConfig(environment: environment) { apiURL = fromEnvironment.baseURL }
        #endif
        return PhotoHostingConfig(hosting: PhotoHosting(rawSetting: hostingSetting), apiURL: apiURL)
    }
}
