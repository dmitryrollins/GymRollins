import SwiftUI

/// Wording for AI-generated exercise media (the "AI" badge and the note it opens).
enum AIPhotoNotice {
    static let title = "AI-generated image"
    static let message = "This image was created with AI to illustrate the exercise. It is not an accurate " +
        "representation and can be wrong: the pose, form, equipment or setup may differ from how the exercise " +
        "should be done. Follow the written instructions, and stop if anything feels wrong."
}

/// Small "AI" capsule on an AI-generated photo. Tapping it explains that the image may be inaccurate.
struct AIPhotoBadge: View {
    @State private var showNotice = false

    var body: some View {
        Button { showNotice = true } label: {
            HStack(spacing: 3) {
                Image(systemName: "sparkles").font(.caption2.weight(.bold))
                Text("AI").font(.caption.weight(.heavy))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("AI-generated image. Double-tap for details.")
        .accessibilityIdentifier("exercise.photo.aiBadge")
        .alert(AIPhotoNotice.title, isPresented: $showNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(AIPhotoNotice.message)
        }
    }
}
