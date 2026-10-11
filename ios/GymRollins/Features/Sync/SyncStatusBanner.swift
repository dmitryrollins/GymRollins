import GymSync
import SwiftUI

/// Glass capsule on Today and Log when sync needs attention: offline, failed, or workouts in conflict (tap to
/// review). Hidden while idle or syncing.
struct SyncStatusBanner: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showConflicts = false

    var body: some View {
        if let state = SyncBannerState.make(env.sync.status) {
            Group {
                if state.reviewable {
                    Button { showConflicts = true } label: { label(state) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sync.banner")
                } else {
                    label(state).accessibilityIdentifier("sync.banner")
                }
            }
            .sheet(isPresented: $showConflicts) { ConflictSheet() }
        }
    }

    private func label(_ state: SyncBannerState) -> some View {
        Label(state.text, systemImage: icon(state.kind))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint(state.kind))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassCapsule(tint: tint(state.kind).opacity(0.18), interactive: state.reviewable)
            .accessibilityElement(children: .combine)
    }

    private func icon(_ kind: SyncBannerState.Kind) -> String {
        switch kind {
        case .offline: "icloud.slash"
        case .error: "exclamationmark.icloud"
        case .conflicts: "arrow.triangle.2.circlepath"
        }
    }

    private func tint(_ kind: SyncBannerState.Kind) -> Color {
        switch kind {
        case .offline: Theme.textSecondary
        case .error: Theme.destructive
        case .conflicts: Theme.record
        }
    }
}
