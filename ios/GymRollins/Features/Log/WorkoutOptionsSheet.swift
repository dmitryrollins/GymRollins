import SwiftUI

/// The "•••" glass menu's sheet: Edit / Delete workout (with its own delete confirmation).
struct WorkoutOptionsSheet: View {
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 40, height: 5)
            row(title: "Edit", systemImage: "pencil", identifier: "detail.edit", destructive: false) {
                dismiss()
                onEdit()
            }
            row(title: "Delete workout", systemImage: "trash", identifier: "detail.delete", destructive: true) {
                showDeleteConfirm = true
            }
        }
        .padding(20)
        // Its two rows at the default sizes; half the screen at accessibility sizes, so Edit and Delete stay on it.
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.medium] : [.height(190)])
        .confirmationDialog("Delete this workout? This can't be undone.", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                dismiss()
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(title: String, systemImage: String, identifier: String, destructive: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(destructive ? Theme.destructive : Theme.textPrimary)
        }
        .padding(12)
        .background(Theme.card, in: .rect(cornerRadius: 14))
        .accessibilityIdentifier(identifier)
    }
}
