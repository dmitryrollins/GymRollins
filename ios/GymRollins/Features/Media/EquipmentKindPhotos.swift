import Foundation

/// Where to find the stock photo of an equipment kind: our Storage bucket first (the owner can add or replace one
/// without an app release), then the copy bundled in `OwnPhotos/`. A listing with no photo of its own shows the first
/// that loads; the photo is only ever displayed, never saved on the listing.
struct EquipmentKindPhotos: Sendable {
    typealias Lookup = @Sendable (String) -> URL?

    private let hosted: Lookup
    private let bundled: Lookup

    init(hosted: @escaping Lookup, bundled: @escaping Lookup) {
        self.hosted = hosted
        self.bundled = bundled
    }

    init(storage: HostedPhotoProvider?, bundled: @escaping Lookup) {
        self.init(hosted: { storage?.kindPhotoURL(kindId: $0) }, bundled: bundled)
    }

    /// No stock photos at all (hermetic UI tests).
    static let none = EquipmentKindPhotos(hosted: { _ in nil }, bundled: { _ in nil })

    /// `OwnPhotos/kind-<kindId>.jpg` in `bundle`.
    static func bundled(_ bundle: Bundle) -> Lookup {
        { kindId in
            guard StoragePhotoManifest.isValidKindID(kindId) else { return nil }
            return bundle.url(forResource: "kind-\(kindId)", withExtension: "jpg",
                              subdirectory: BundledOwnPhotoProvider.folder)
        }
    }

    /// Hosted first, then bundled, so a failed download falls back to the copy in the app.
    func candidates(kindId: String) -> [URL] {
        guard StoragePhotoManifest.isValidKindID(kindId) else { return [] }
        return [hosted(kindId), bundled(kindId)].compactMap(\.self)
    }
}
