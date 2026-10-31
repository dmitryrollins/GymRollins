import GymData
import SwiftUI
import UIKit

/// What a gym listing shows for a photo: its own, else our stock photo of its kind (marked "Sample", display only), else
/// the dumbbell placeholder. A stock photo is never saved on the listing; the tile keeps its size while it loads.
struct ListingPhotoView: View {
    /// What fills the frame. Plan 21 adds a case for a photo another gym shared of the same item, between the two.
    private enum Shown {
        case own(String)
        case stock(UIImage)
        case placeholder
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.displayScale) private var scale
    let photoFile: String?
    let kindId: String?
    var width: CGFloat = 52
    var height: CGFloat?
    var full = false
    var cornerRadius: CGFloat = 12
    /// Puts the "Sample photo, not from this gym" caption under a stock photo.
    var showsNote = false
    @State private var stock: UIImage?
    /// The kind `stock` is the photo of, so a new kind never shows the old one's while it loads.
    @State private var stockKind: String?

    init(listing: GymListing, width: CGFloat, height: CGFloat? = nil, full: Bool = false, cornerRadius: CGFloat = 12,
         showsNote: Bool = false) {
        self.init(photoFile: listing.photoFile, kindId: listing.item.kindId, width: width, height: height,
                  full: full, cornerRadius: cornerRadius, showsNote: showsNote)
    }

    init(photoFile: String?, kindId: String?, width: CGFloat, height: CGFloat? = nil, full: Bool = false,
         cornerRadius: CGFloat = 12, showsNote: Bool = false) {
        self.photoFile = photoFile
        self.kindId = kindId
        self.width = width
        self.height = height
        self.full = full
        self.cornerRadius = cornerRadius
        self.showsNote = showsNote
    }

    private var displayHeight: CGFloat { height ?? width }
    private var compact: Bool { width < 100 }

    private var shown: Shown {
        if let photoFile { return .own(photoFile) }
        if let stock { return .stock(stock) }
        return .placeholder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            frame
            if showsNote, case .stock = shown {
                Text("Sample photo, not from this gym. Add yours to show the real one.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("listing.samplePhotoNote")
            }
        }
        .task(id: LoadKey(photoFile: photoFile, kindId: kindId, revision: env.media.revision.value)) { await loadStock() }
    }

    @ViewBuilder
    private var frame: some View {
        switch shown {
        case let .own(file):
            GymPhotoView(fileName: file, width: width, height: height, full: full, cornerRadius: cornerRadius,
                         placeholderSymbol: "dumbbell")
        case let .stock(image):
            GymPhotoView(fileName: nil, width: width, height: height, cornerRadius: cornerRadius,
                         placeholderSymbol: "dumbbell")
                .overlay {
                    Image(uiImage: image).resizable().scaledToFill().accessibilityHidden(true)
                        .frame(width: width, height: displayHeight).clipped()
                }
                .overlay(alignment: .topLeading) { sampleCapsule }
                .clipShape(.rect(cornerRadius: cornerRadius))
        case .placeholder:
            GymPhotoView(fileName: nil, width: width, height: height, cornerRadius: cornerRadius,
                         placeholderSymbol: "dumbbell")
        }
    }

    /// The look of the "AI" badge's capsule, without being a button.
    private var sampleCapsule: some View {
        Text("Sample")
            .font(compact ? .caption2.weight(.heavy) : .caption.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 5 : 8)
            .padding(.vertical, compact ? 3 : 5)
            .background(.black.opacity(0.55), in: .capsule)
            .padding(compact ? 4 : 8)
            .accessibilityIdentifier("listing.samplePhoto")
    }

    private struct LoadKey: Equatable {
        let photoFile: String?
        let kindId: String?
        let revision: Int
    }

    /// Shows the bundled photo at once, then swaps in the hosted one if it loads: a gym-floor screen must not wait on
    /// the network for a picture that is already in the app. `candidates` lists hosted first, so this walks it backwards.
    /// A failed load keeps whatever is showing; the placeholder stays when neither loads.
    private func loadStock() async {
        guard photoFile == nil, let kindId else { stock = nil; stockKind = nil; return }
        if stockKind != kindId { stock = nil }
        let maxPixels = max(width, displayHeight) * scale
        for url in env.media.kindPhotos.candidates(kindId: kindId).reversed() {
            let image = try? await env.media.loader.image(for: url, maxPixelSize: maxPixels)
            guard !Task.isCancelled else { return }
            if let image {
                stock = image
                stockKind = kindId
            }
        }
    }
}
