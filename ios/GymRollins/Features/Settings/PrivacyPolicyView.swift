import SwiftUI

/// Plain-language privacy summary: what's stored, what Claude can see, and what GymRollins never does.
struct PrivacyPolicyView: View {
    private static let points = [
        "Your workouts, plan, weigh-ins and profile are stored on this iPhone, and in your account if you sign in.",
        "Claude can only read what you allow in the Claude section of Settings, and only proposes plan changes "
            + "you review (or explicitly allow it to apply automatically).",
        "There are no ads and no third-party trackers. Your data is never sold or shared with advertisers.",
        "Location is asked for only to suggest the gym you're at. It is sent to Apple Maps for that search and "
            + "isn't stored by GymRollins.",
        "Gym photos are cleaned on your iPhone first: location data is removed and any faces it finds are blurred. "
            + "\"This phone only\" photos stay on this iPhone. Synced ones go to your account, where only you can see "
            + "them. Shared ones are public: anyone can see them, with no account.",
        "If you report something, moderators see the reason and your note, but not who sent it.",
        "Sharing a workout link sends only its exercises, sets and reps: no weights, name or history.",
        "Deleting your account removes your data and photos from the server and this iPhone. Equipment you shared "
            + "stays listed at the gym, without your name, photos or notes. Reports you sent stay, without your name "
            + "or note.",
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
