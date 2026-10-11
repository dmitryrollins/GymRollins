import SwiftUI

/// Renders the bundled `CREDITS.md` (exercise data MIT notice, exercise photo credit, font OFL, data-model
/// attribution) as plain text.
struct CreditsView: View {
    private var text: String {
        guard let url = Bundle.main.url(forResource: "CREDITS", withExtension: "md"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "Credits are unavailable in this build."
        }
        return contents
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("# ") {
                        DisplayTitle(text: String(line.dropFirst(2)), size: 30)
                    } else if line.hasPrefix("- ") {
                        Text(String(line.dropFirst(2))).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    } else if !line.isEmpty {
                        Text(line).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    }
                }
            }
            .padding(Theme.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.credits.view")
    }

    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }
}
