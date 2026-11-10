import SwiftUI

/// Settings' "Injuries / limits" row: the note (wrapping, so a long one isn't clipped), or None.
struct LimitsSettingsRow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationLink { LimitsSettingsView() } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Injuries / limits")
                Text(env.profile.limits.isEmpty ? "None" : env.profile.limits)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityIdentifier("settings.limits")
    }
}
