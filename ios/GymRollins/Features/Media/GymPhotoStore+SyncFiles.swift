import Foundation
import GymSync

/// What `SyncEngine` needs from the photo folder. A downloaded picture is already cleaned (it went through
/// `GymPhotoProcessor` on the phone that uploaded it), so only its thumbnail is made here.
extension GymPhotoStore: GymPhotoFiles {
    func data(file: String) -> Data? {
        guard Self.isSafeName(file) else { return nil }
        return try? Data(contentsOf: url(file))
    }

    func save(_ jpeg: Data, file: String) throws {
        guard Self.isSafeName(file) else { throw GymPhotoStoreError.invalidFileName }
        let thumbnail = try GymPhotoProcessor.thumbnail(ofCleaned: jpeg)
        try save(ProcessedGymPhoto(jpeg: jpeg, thumbnail: thumbnail), as: file)
    }

    func delete(file: String) throws { try delete(file) }
}
