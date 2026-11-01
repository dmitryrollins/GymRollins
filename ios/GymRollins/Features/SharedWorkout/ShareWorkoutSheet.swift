import GymCore
import SwiftUI

/// "Share workout": a button that makes its link when tapped, so it always sends the workout as it is now.
struct ShareWorkoutButton: View {
    @Environment(AppEnvironment.self) private var env
    let identifier: String
    let sources: () -> [SharedWorkout.Source]
    @State private var model: ShareWorkoutModel?

    var body: some View {
        SecondaryGlassButton(title: "Share workout", identifier: identifier) {
            model = ShareWorkoutModel.make(sources: sources(), library: env.library, link: .configured)
        }
        .sheet(item: $model) { ShareWorkoutSheet(model: $0) }
    }
}

/// The QR code and "Send link" (spec section 6).
struct ShareWorkoutSheet: View {
    let model: ShareWorkoutModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DisplayTitle(text: "Share workout", size: 34).accessibilityAddTraits(.isHeader)
                    if let url = model.url { sharing(url) } else { nothing }
                    if let notice = model.cutOffNotice { line(notice, identifier: "share.cutOff") }
                    if let notice = model.leftOutNotice { line(notice, identifier: "share.leftOut") }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("share.done")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func sharing(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let code = model.qrCode {
                Image(code, scale: 1, label: Text("QR code for this workout"))
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("share.qr")
            }
            ShareLink(item: url, preview: SharePreview("GymRollins workout")) {
                Label("Send link", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("share.send")
            line("Your partner sees this workout with their own weights.", identifier: "share.note")
        }
    }

    private var nothing: some View {
        line(model.nothingMessage, identifier: "share.nothing")
    }

    private func line(_ text: String, identifier: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}
