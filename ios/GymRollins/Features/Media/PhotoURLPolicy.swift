import Foundation

/// Which photo URLs may be downloaded. Production is https-only. A DEBUG build may additionally load plain http from
/// the local Supabase stack (127.0.0.1 / localhost, or the configured `SUPABASE_URL` host when it is a loopback/LAN
/// address), so Storage-hosted photos can be tested against `scripts/supabase-up.sh`. A Release build never gets an
/// http allowance: `forBuild` returns `.httpsOnly` there and `debugLocal` doesn't exist.
struct PhotoURLPolicy: Sendable, Equatable {
    /// Hosts (lowercased) that may be fetched over plain http. Empty = https only.
    let insecureHosts: Set<String>

    static let httpsOnly = PhotoURLPolicy(insecureHosts: [])

    func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else {
            return false
        }
        if scheme == "https" { return true }
        return scheme == "http" && insecureHosts.contains(host)
    }

    /// The policy for this build: DEBUG allows http to the local dev hosts, Release is https-only.
    static func forBuild(supabaseURL: URL?) -> PhotoURLPolicy {
        #if DEBUG
        return debugLocal(supabaseURL: supabaseURL)
        #else
        return .httpsOnly
        #endif
    }

    #if DEBUG
    /// DEBUG only: http to loopback, plus the Supabase host when it is a local/LAN address (a device testing against
    /// the Mac's stack). A public host never gets http, even in DEBUG.
    static func debugLocal(supabaseURL: URL?) -> PhotoURLPolicy {
        var hosts: Set<String> = ["127.0.0.1", "localhost"]
        if let host = supabaseURL?.host()?.lowercased(), isLocalDevHost(host) { hosts.insert(host) }
        return PhotoURLPolicy(insecureHosts: hosts)
    }
    #endif

    /// Loopback, link-local, RFC 1918 private IPv4 addresses and mDNS `.local` names.
    static func isLocalDevHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        if host.hasSuffix(".local"), host.count > ".local".count { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 256) <= 255 }),
              let first = octets[0], let second = octets[1] else { return false }
        switch first {
        case 127, 10: return true
        case 192: return second == 168
        case 172: return (16...31).contains(second)
        case 169: return second == 254
        default: return false
        }
    }
}
