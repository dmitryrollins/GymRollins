import SwiftUI
import UIKit

/// A prepared export file, presented once through the system share sheet.
struct ExportShare: Identifiable {
    let id = UUID()
    let url: URL
}

/// `UIActivityViewController` for one export file. `onComplete` fires when the user finishes or cancels, so the
/// caller can dismiss the sheet (and its `onDismiss` deletes the file).
struct ExportShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The Settings "Claude connection" badge. Profile permission flags default to on, so they say what Claude *may*
/// do, not that a connector exists; the badge reflects actual use of the MCP server by the signed-in account.
enum ClaudeConnectionBadge: Equatable {
    case checking, connected, notConnected

    static func make(signedIn: Bool, checked: Bool, lastUse: Date?) -> ClaudeConnectionBadge {
        guard signedIn else { return .notConnected }
        if lastUse != nil { return .connected }
        return checked ? .notConnected : .checking
    }

    var text: String {
        switch self {
        case .checking: "Checking\u{2026}"
        case .connected: "Connected"
        case .notConnected: "Not connected"
        }
    }

    var kind: Badge.Kind { self == .connected ? .success : .neutral }
}
