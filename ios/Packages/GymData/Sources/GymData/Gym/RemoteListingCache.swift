import Foundation
import GymCore
import SwiftData

/// Writes a server listing into the local rows. A refresh and the duplicate the user chose go through the same code, so
/// a cached listing looks the same whichever way it arrived.
struct RemoteListingCache {
    let context: ModelContext
    let now: () -> Date

    func insert(_ entry: RemoteListing, itemId: UUID, gymId: UUID) -> GymListingRecord {
        let row = GymListingRecord(id: entry.id, gymId: gymId, itemId: itemId, kindId: entry.kindId,
                                   loadsData: Data(), quantity: entry.quantity, notes: entry.notes, photoFile: nil,
                                   now: now())
        row.visibilityRaw = GymVisibility.shared.rawValue
        row.uploadStateRaw = UploadState.uploaded.rawValue
        update(row, from: entry, itemId: itemId)
        context.insert(row)
        return row
    }

    func update(_ row: GymListingRecord, from entry: RemoteListing, itemId: UUID) {
        row.itemId = itemId
        row.kindId = entry.kindId
        row.loadsData = entry.loads.flatMap { try? JSONEncoder().encode($0) } ?? Data("{}".utf8)
        row.quantity = entry.quantity
        row.notes = entry.notes
        row.remotePhotoPath = entry.photoPath
        row.statusRaw = entry.loads == nil ? ListingStatus.unsupported.rawValue : Self.status(entry.status).rawValue
        row.confirmCount = entry.confirmCount
        row.confirmedByMe = entry.confirmedByMe
        row.isOwn = entry.isMine
        row.remoteId = entry.id
        if row.uploadStateRaw != UploadState.queued.rawValue { row.uploadStateRaw = UploadState.uploaded.rawValue }
        row.updatedAt = now()
    }

    static func status(_ raw: String) -> ListingStatus {
        ListingStatus(rawValue: raw) ?? .unsupported
    }
}
