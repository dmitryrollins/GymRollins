import Foundation
import GymCore
import SwiftData
import os

// Photos in the public bucket: what the queue uploaded for a share that didn't happen is deleted again.
extension ShareOutbox {
    /// Best effort, never failing the flow: an object that can't be deleted is logged and stays (a server sweep
    /// is the backstop).
    func deleteUploaded(_ path: String) async {
        do {
            try await transport.deleteSharedPhoto(path: path)
        } catch is CancellationError {
            return
        } catch {
            Self.log.error("Delete of an uploaded photo failed: \(String(describing: error), privacy: .public)")
        }
    }

    func deleteInBackground(_ path: String) {
        cleanups.append(Task { await self.deleteUploaded(path) })
    }

    /// Waits for the deletions started in the background (tests, and a caller that must not quit before they end).
    public func finishCleanups() async {
        let running = cleanups
        cleanups = []
        for task in running { await task.value }
    }

    /// Sign-out with shares still queued: deletes the photos they already uploaded, while the session can. Offline,
    /// or past `limit`, the objects stay in the bucket. Run before `invalidate()` and before the session ends.
    public func discardQueuedPhotos(userId: UUID, limit: Duration = .seconds(5)) async {
        let queued = ((try? rows()) ?? []).filter { $0.kindRaw == Kind.share.rawValue && $0.ownerId == userId }
        let listings = queued.compactMap { try? repository.listingRecord($0.targetId) }
        let found = listings.compactMap { listing in listing.remotePhotoPath.map { (listing.id, $0) } }
        guard !found.isEmpty else { return }
        let work = Task {
            for (id, path) in found where !Task.isCancelled {
                guard (try? await deleteOrThrow(path)) != nil else { continue }
                try? repository.listingRecord(id)?.remotePhotoPath = nil
            }
            try? context.save()
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            work.cancel()
        }
        await work.value
        timer.cancel()
    }

    private func deleteOrThrow(_ path: String) async throws {
        do {
            try await transport.deleteSharedPhoto(path: path)
        } catch {
            Self.log.error("Delete of a queued photo failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Caches the listing the user chose from a duplicates answer when this phone doesn't have it.
    func cacheChosen(_ id: UUID, at gymId: UUID, from listingId: UUID) throws {
        guard try repository.listingRecord(id) == nil,
              let chosen = try duplicates(listingId: listingId).first(where: { $0.id == id }) else { return }
        let item = try repository.itemRecord(kindId: chosen.kindId, brand: chosen.brand, model: chosen.model)
        _ = RemoteListingCache(context: context, now: now).insert(chosen, itemId: item.id, gymId: gymId)
    }
}
