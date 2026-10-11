import Foundation

/// Short number formats for the small watch screen.
public enum WatchFormat {
    /// "135", "62.5", "61.2" — at most one decimal, no trailing ".0".
    public static func weight(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }

    /// "0:05", "1:30", "1:02:03".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (h, m, s) = (total / 3_600, (total % 3_600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// A rest countdown: rounds up, so it reads "0:01" until the very end.
    public static func countdown(_ seconds: TimeInterval) -> String { clock(seconds.rounded(.up)) }
}
