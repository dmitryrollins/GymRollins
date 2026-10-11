import SwiftUI

/// Small "Photo: <author> · <license>" capsule on a licensed photo (wger, CC-BY / CC-BY-SA). Tapping it opens the
/// full credit: title, author, license and source links, and that the image is resized/cropped for display.
struct PhotoCreditBadge: View {
    let credit: PhotoCredit
    @State private var showDetails = false

    var body: some View {
        Button { showDetails = true } label: {
            Text(credit.caption)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(credit.caption). Double-tap for the photo credit.")
        .accessibilityIdentifier("exercise.photo.credit")
        .sheet(isPresented: $showDetails) {
            PhotoCreditSheet(credit: credit)
                .presentationDetents([.medium, .large])
        }
    }
}

/// The full attribution for one photo.
struct PhotoCreditSheet: View {
    let credit: PhotoCredit
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Title", credit.title, id: "title")
                    row("Author", credit.author, id: "author")
                    if let url = credit.licenseURL {
                        Link(destination: url) { linkRow("License", credit.license) }
                            .accessibilityIdentifier("photoCredit.license")
                    } else {
                        row("License", credit.license, id: "license")
                    }
                    if let url = credit.sourceURL {
                        Link(destination: url) { linkRow("Source", url.host() ?? url.absoluteString) }
                            .accessibilityIdentifier("photoCredit.source")
                    }
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Photo credit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("photoCredit.done")
                }
            }
        }
        .accessibilityIdentifier("photoCredit.sheet")
    }

    private var footer: String {
        let modified = credit.modified ? "Resized and cropped for display. " : ""
        return modified + "Shared under the license above; the photo is loaded from its source when first shown."
    }

    private func row(_ label: String, _ value: String, id: String) -> some View {
        LabeledContent(label, value: value)
            .accessibilityIdentifier("photoCredit.\(id)")
    }

    private func linkRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                Text(value)
                Image(systemName: "arrow.up.right.square").accessibilityHidden(true)
            }
        }
    }
}
