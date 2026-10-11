import Foundation
import GymSync

/// Where GymRollins' own photos come from, set per build with `PHOTO_HOSTING` (xcconfig -> Info.plist):
/// - `bundle` (default): only the photos bundled in Resources/OwnPhotos.
/// - `storage`: the public `exercise-photos` bucket of the configured Supabase project (manifest-driven), with the
///   bundled photos as fallback. See docs/media/README.md ("Hosting").
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
    /// The Supabase project URL (nil when the build has no valid Supabase config).
    let supabaseURL: URL?

    /// From Info.plist; in DEBUG, `PHOTO_HOSTING` / `SUPABASE_URL` + `SUPABASE_ANON_KEY` environment variables win (like
    /// sync), so tests and debug runs can point at the local stack.
    static func resolve(info: [String: Any], environment: [String: String]) -> PhotoHostingConfig {
        var hostingSetting = info[PhotoHosting.infoKey] as? String
        var supabaseURL = (try? SupabaseConfig(info: info))?.url
        #if DEBUG
        if let override = environment[PhotoHosting.infoKey] { hostingSetting = override }
        if let fromEnvironment = try? SupabaseConfig(environment: environment) { supabaseURL = fromEnvironment.url }
        #endif
        return PhotoHostingConfig(hosting: PhotoHosting(rawSetting: hostingSetting), supabaseURL: supabaseURL)
    }
}
