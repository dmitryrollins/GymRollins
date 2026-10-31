import GymData
import SwiftUI
import UIKit

/// What a gym listing shows for a photo: its own, else a picture another gym took of the same item (marked "Other
/// gym"), else our stock photo of its kind (marked "Sample"), else the dumbbell placeholder. Neither borrowed picture
/// is ever saved on the listing; the tile keeps its size while they load.
struct ListingPhotoView: View {
    private enum Shown {
        case own(String)
        case catalog(UIImage)
        case stock(UIImage)
        case placeholder
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.displayScale) private var scale
    let photoFile: String?
    let kindId: String?
    /// The item's picture in the shared catalogue, from another gym's listing.
    var catalogPhotoPath: String?
    var width: CGFloat = 52
    var height: CGFloat?
    var full = false
    var cornerRadius: CGFloat = 12
    /// Puts the caption under a borrowed or stock photo.
    var showsNote = false
    @State private var stock: UIImage?
    /// The kind `stock` is the photo of, so a new kind never shows the old one's while it loads.
    @State private var stockKind: String?
    @State private var catalog: UIImage?
    /// The path `catalog` was loaded from, so a different picture never shows the old one while it loads.
    @State private var catalogPath: String?

    init(listing: GymListing, width: CGFloat, height: CGFloat? = nil, full: Bool = false, cornerRadius: CGFloat = 12,
         showsNote: Bool = false) {
        self.init(photoFile: listing.photoFile, kindId: listing.item.kindId,
                  catalogPhotoPath: listing.item.catalogPhotoPath, width: width, height: height, full: full,
                  cornerRadius: cornerRadius, showsNote: showsNote)
    }

    init(photoFile: String?, kindId: String?, catalogPhotoPath: String? = nil, width: CGFloat, height: CGFloat? = nil,
         full: Bool = false, cornerRadius: CGFloat = 12, showsNote: Bool = false) {
        self.photoFile = photoFile
        self.kindId = kindId
        self.catalogPhotoPath = catalogPhotoPath
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
        if let catalog, catalogPath == catalogPhotoPath { return .catalog(catalog) }
        if let stock { return .stock(stock) }
        return .placeholder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            frame
            if showsNote { note }
        }
        .task(id: LoadKey(photoFile: photoFile, kindId: kindId, revision: env.media.revision.value)) { await loadStock() }
        .task(id: CatalogKey(photoFile: photoFile, path: catalogPhotoPath)) { await loadCatalog() }
    }

    @ViewBuilder
    private var note: some View {
        switch shown {
        case .stock:
            Text("Sample photo, not from this gym. Add yours to show the real one.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("listing.samplePhotoNote")
        case .catalog:
            Text("Photo from another gym. Add yours to show the real one here.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("listing.catalogPhotoNote")
        case .own, .placeholder:
            EmptyView()
        }
    }

    @ViewBuilder
    private var frame: some View {
        switch shown {
        case let .own(file):
            GymPhotoView(fileName: file, width: width, height: height, full: full, cornerRadius: cornerRadius,
                         placeholderSymbol: "dumbbell")
        case let .catalog(image):
            borrowed(image, capsule: "Other gym", identifier: "listing.catalogPhoto")
        case let .stock(image):
            borrowed(image, capsule: "Sample", identifier: "listing.samplePhoto")
        case .placeholder:
            GymPhotoView(fileName: nil, width: width, height: height, cornerRadius: cornerRadius,
                         placeholderSymbol: "dumbbell")
        }
    }

    private func borrowed(_ image: UIImage, capsule: String, identifier: String) -> some View {
        GymPhotoView(fileName: nil, width: width, height: height, cornerRadius: cornerRadius,
                     placeholderSymbol: "dumbbell")
            .overlay {
                Image(uiImage: image).resizable().scaledToFill().accessibilityHidden(true)
                    .frame(width: width, height: displayHeight).clipped()
            }
            .overlay(alignment: .topLeading) { capsuleLabel(capsule, identifier: identifier) }
            .clipShape(.rect(cornerRadius: cornerRadius))
    }

    /// The look of the "AI" badge's capsule, without being a button.
    private func capsuleLabel(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(compact ? .caption2.weight(.heavy) : .caption.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 5 : 8)
            .padding(.vertical, compact ? 3 : 5)
            .background(.black.opacity(0.55), in: .capsule)
            .padding(compact ? 4 : 8)
            .accessibilityIdentifier(identifier)
    }

    private struct LoadKey: Equatable {
        let photoFile: String?
        let kindId: String?
        let revision: Int
    }

    private struct CatalogKey: Equatable {
        let photoFile: String?
        let path: String?
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

    /// The picture another gym took of this item, loaded by URL: it is shown, never saved. Offline or on a failed
    /// load nothing changes, so the stock photo or the placeholder stays.
    private func loadCatalog() async {
        guard photoFile == nil, let path = catalogPhotoPath, let url = env.catalogPhotoURL(path) else {
            catalog = nil
            catalogPath = nil
            return
        }
        let image = try? await env.media.loader.image(for: url, maxPixelSize: max(width, displayHeight) * scale)
        guard !Task.isCancelled else { return }
        catalog = image
        catalogPath = image == nil ? nil : path
    }
}
