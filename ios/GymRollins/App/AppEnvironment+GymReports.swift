import Foundation
import GymData

/// Reporting and blocking shared gym content. The listing leaves the screens at once; the queue tells the server.
extension AppEnvironment {
    func reportListing(_ id: UUID, reason: ReportReason, note: String?) throws {
        try gymSharing.outbox.enqueueReport(listingId: id, reason: reason, note: note, ownerId: try requireSharingUser())
        sharingChanged()
    }

    func reportGym(_ id: UUID, reason: ReportReason, note: String?) throws {
        try gymSharing.outbox.enqueueGymReport(gymId: id, reason: reason, note: note,
                                               ownerId: try requireSharingUser())
        sharingChanged()
    }

    /// The picture a listing borrows from another gym's listing: it goes from the screen, the listing stays.
    func reportCataloguePhoto(onListing id: UUID, reason: ReportReason, note: String?) throws {
        try gymSharing.outbox.enqueueCataloguePhotoReport(listingId: id, reason: reason, note: note,
                                                          ownerId: try requireSharingUser())
        sharingChanged()
    }

    /// Hides everything by the author of this shared listing, which the server resolves.
    func blockAuthor(ofListing id: UUID) throws {
        try gymSharing.outbox.enqueueBlock(listingId: id, ownerId: try requireSharingUser())
        sharingChanged()
    }

    /// Clears every block, then refreshes the current gym so what they hid is back.
    @discardableResult
    func unblockAllAuthors() async throws -> Int {
        let cleared = try await gymSharing.outbox.unblockAll()
        gymsChanged()
        return cleared
    }
}
