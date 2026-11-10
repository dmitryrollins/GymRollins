import SwiftUI

/// "Report a content problem: <address>" in About, for complaints about shared gym content. It shows only when an
/// address is set, and the address opens the mail app.
struct ContentContactRow: View {
    let email: String?

    static func label(for email: String?) -> String? {
        guard let email, !email.isEmpty else { return nil }
        return "Report a content problem: \(email)"
    }

    static func url(for email: String?) -> URL? {
        guard let email, !email.isEmpty else { return nil }
        return URL(string: "mailto:\(email)")
    }

    var body: some View {
        if let label = Self.label(for: email) {
            if let url = Self.url(for: email) {
                Link(label, destination: url).accessibilityIdentifier("about.contentContact")
            } else {
                Text(label).accessibilityIdentifier("about.contentContact")
            }
        }
    }
}
