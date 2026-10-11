import SwiftUI

/// Plain-language privacy summary: what's stored, what Claude can see, and what GymRollins never does.
struct PrivacyPolicyView: View {
    private static let points = [
        "Your workouts, plan, weigh-ins and profile are stored on this iPhone, and in your account if you sign in.",
        "Claude can only read what you allow in the Claude section of Settings, and only proposes plan changes "
            + "you review (or explicitly allow it to apply automatically).",
        "There are no ads and no third-party trackers. Your data is never sold or shared.",
        "Deleting your account removes your data from the server and this iPhone.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DisplayTitle(text: "Privacy", size: 34)
                ForEach(Array(Self.points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                        Text(point).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    }
                }
            }
            .padding(Theme.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.privacy.view")
    }
}
