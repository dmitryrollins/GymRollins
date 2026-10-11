import GymCore
import SwiftUI

/// "N rows skipped" for CSV rows the importer (`WorkoutImporters`) rejected, expandable to each line number and reason, so an import
/// is never reported as a clean success while history is silently missing. Shown on the preview and the summary.
struct SkippedRowsCard: View {
    let errors: [ImportRowError]
    @State private var expanded = false

    static func title(count: Int) -> String { count == 1 ? "1 row skipped" : "\(count) rows skipped" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.destructive)
                    Text(Self.title(count: errors.count)).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityIdentifier("result.skipped")
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("result.skipped.toggle")
            if expanded {
                ForEach(Array(errors.enumerated()), id: \.offset) { index, rowError in
                    Text("Line \(rowError.line): \(rowError.message)")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("result.skipped.row.\(index)")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }
}
