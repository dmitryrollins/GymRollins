import Foundation
import GymCore
import SwiftData

// Reports and blocks. Hiding is immediate on the phone and the server hears about it when it can: a row that the
// server refuses for good stops hiding, so the user is never left unsure whether the listing was reported.
extension ShareOutbox {
    // MARK: - Queueing

    /// Reports a shared listing. It leaves every list at once, unless it is the user's own: the server answers `own`
    /// for those, which counts as sent, and nothing is hidden.
    public func enqueueReport(listingId: UUID, reason: ReportReason, note: String?, ownerId: UUID) throws {
        let listing = try sharedListing(listingId)
        try queue(.report, type: .listing, target: listingId, reason: reason, note: note, ownerId: ownerId,
                  hides: !listing.isOwn)
        if !listing.isOwn { listing.hiddenLocally = true }
        try context.save()
    }

    /// Reports a gym that is on the server. The gym stays on the phone: it may be the user's own, and reporting it
    /// doesn't change what it lists here.
    public func enqueueGymReport(gymId: UUID, reason: ReportReason, note: String?, ownerId: UUID) throws {
        guard let serverId = try repository.gymRecord(gymId)?.remoteId else {
            throw GymDataError.invalidInput("This gym isn't shared yet, so there is nothing to report.")
        }
        try queue(.report, type: .gym, target: serverId, reason: reason, note: note, ownerId: ownerId)
        try context.save()
    }

    /// Reports the borrowed catalogue photo a listing shows, which belongs to another listing. The source is the
    /// target; the listing stays and loses the picture on the phone until the next refresh brings back a valid one.
    public func enqueueCataloguePhotoReport(listingId: UUID, reason: ReportReason, note: String?,
                                            ownerId: UUID) throws {
        guard let listing = try repository.listingRecord(listingId),
              let item = try itemRecord(listing.itemId),
              item.catalogPhotoPath != nil, let source = item.catalogPhotoListingId else {
            throw GymDataError.invalidInput("There is no photo from another gym to report.")
        }
        try queue(.report, type: .listing, target: source, reason: reason, note: note, ownerId: ownerId,
                  aboutPhoto: true)
        item.catalogPhotoPath = nil
        item.catalogPhotoListingId = nil
        try context.save()
    }

    /// Hides everything the listing's author wrote. The phone doesn't know the author, so this listing goes now and
    /// the rest at the next refresh, once the server stops returning them.
    public func enqueueBlock(listingId: UUID, ownerId: UUID) throws {
        let listing = try sharedListing(listingId)
        guard !listing.isOwn else { throw GymDataError.invalidInput("That is your own listing.") }
        try queue(.block, type: .listing, target: listingId, reason: nil, note: nil, ownerId: ownerId, hides: true)
        listing.hiddenLocally = true
        try context.save()
    }

    /// Clears the user's blocks on the server, then makes every gym refresh at its next open, so what the blocks hid
    /// comes back. Returns how many blocks there were. Called with the session gone, it leaves the rows alone.
    public func unblockAll() async throws -> Int {
        let token = generation
        let cleared = try await transport.unblockAll()
        guard token == generation else { return cleared }
        for gym in try context.fetch(FetchDescriptor<GymRecord>()) { gym.catalogRefreshedAt = nil }
        try context.save()
        return cleared
    }

    /// The notice for a refused report, once.
    public func takeReportNotice() -> String? {
        defer { reportNotice = nil }
        return reportNotice
    }

    // MARK: - Running

    func sendReport(_ row: ShareOutboxRecord, token: Int) async throws {
        guard let type = row.targetTypeRaw.flatMap(GymTargetType.init), let reason = row.reasonRaw.flatMap(ReportReason.init)
        else { return try drop(row) }
        do {
            do {
                try await transport.report(targetType: type, targetId: row.targetId, reason: reason, note: row.note)
            } catch GymCatalogError.noteRefused where row.note != nil {
                // The report matters more than its note: send it again without.
                try ensureCurrent(token)
                try await transport.report(targetType: type, targetId: row.targetId, reason: reason, note: nil)
            }
        } catch GymCatalogError.unknownTarget {
            // Gone already: nothing to report, and the listing stays out of sight.
        }
        try ensureCurrent(token)
        try drop(row)
    }

    func sendBlock(_ row: ShareOutboxRecord, token: Int) async throws {
        guard let type = row.targetTypeRaw.flatMap(GymTargetType.init) else { return try drop(row) }
        do {
            try await transport.blockAuthor(targetType: type, targetId: row.targetId)
        } catch GymCatalogError.unknownTarget {
            // The listing is gone, and so is the way to find its author.
        }
        try ensureCurrent(token)
        try drop(row)
    }

    /// The server refused the row for good: it is dropped, what it hid comes back, and the user is told.
    func settleModeration(_ row: ShareOutboxRecord, _ error: Error) throws {
        Self.log.error("Dropped a \(row.kindRaw, privacy: .public) the server refused: \(String(describing: error), privacy: .public)")
        if row.hidesListing, let listing = try repository.listingRecord(row.targetId) { listing.hiddenLocally = false }
        let block = Kind(rawValue: row.kindRaw) == .block
        switch error as? GymCatalogError {
        case .dailyLimit: reportNotice = Self.reportDailyLimit
        default: reportNotice = block ? Self.couldNotBlock : Self.couldNotReport
        }
        try drop(row)
    }

    // MARK: - Helpers

    private func drop(_ row: ShareOutboxRecord) throws {
        context.delete(row)
        try context.save()
    }

    private func sharedListing(_ id: UUID) throws -> GymListingRecord {
        guard let listing = try repository.listingRecord(id),
              listing.visibilityRaw == GymVisibility.shared.rawValue,
              listing.uploadStateRaw == UploadState.uploaded.rawValue else {
            throw GymDataError.invalidInput("Only a listing shared at a gym can be reported.")
        }
        return listing
    }

    /// Asking twice queues it once.
    private func queue(_ kind: Kind, type: GymTargetType, target: UUID, reason: ReportReason?, note: String?,
                       ownerId: UUID, hides: Bool = false, aboutPhoto: Bool = false) throws {
        let queued = try rows().contains {
            $0.kindRaw == kind.rawValue && $0.targetTypeRaw == type.rawValue && $0.targetId == target
                && $0.ownerId == ownerId
        }
        guard !queued else { return }
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(ShareOutboxRecord(kind: kind, targetId: target, ownerId: ownerId, targetType: type,
                                         reason: reason, note: text?.isEmpty == false ? text : nil,
                                         hidesListing: hides, aboutPhoto: aboutPhoto, now: now()))
    }
}

/// What the queue still has to say about listings and pictures, so a refresh doesn't undo it.
struct QueuedModeration {
    /// Listings hidden while their report or block waits.
    let hiding: Set<UUID>
    /// Listings whose picture was reported and is still borrowed by others.
    let reportedPhotos: Set<UUID>

    init(context: ModelContext) throws {
        let rows = try context.fetch(FetchDescriptor<ShareOutboxRecord>()).filter {
            $0.kindRaw == ShareOutboxRecord.Kind.report.rawValue || $0.kindRaw == ShareOutboxRecord.Kind.block.rawValue
        }
        hiding = Set(rows.filter(\.hidesListing).map(\.targetId))
        reportedPhotos = Set(rows.filter(\.aboutPhoto).map(\.targetId))
    }
}
