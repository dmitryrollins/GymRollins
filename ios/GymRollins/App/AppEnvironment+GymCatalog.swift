import Foundation
import GymCore
import GymData
import GymSync
import Supabase
import UIKit

/// The shared catalogue's pieces on the phone: the server, the cache of other people's listings, the queue of shares
/// and the downloader for their pictures.
@MainActor
final class GymSharing {
    let transport: any GymCatalogTransport
    let client: GymCatalogClient
    let outbox: ShareOutbox
    let photos: GymPhotoCache
    /// Gyms being refreshed right now, so a second ask for the same gym doesn't start a second download.
    var refreshing: Set<UUID> = []
    /// Pictures borrowed from the catalogue, by path: shown, never saved. Tiles of the same item share one download.
    let borrowedPictures = NSCache<NSString, UIImage>()

    init(repository: GymRepository, transport: any GymCatalogTransport, knownKinds: Set<String>, photos: GymPhotoCache,
         photoData: @escaping (String) -> Data?, now: @escaping () -> Date) {
        self.transport = transport
        self.photos = photos
        self.client = GymCatalogClient(repository: repository, transport: transport, knownKinds: knownKinds, now: now)
        self.outbox = ShareOutbox(repository: repository, transport: transport, photoData: photoData, now: now)
    }

    /// The session is ending or changing: requests still on the wire must not touch the rows when they come back.
    func invalidate() {
        client.invalidate()
        outbox.invalidate()
    }
}

/// Stands in when the build has no Supabase config: reads find nothing, writes need an account.
struct UnavailableGymCatalogTransport: GymCatalogTransport {
    func publicGym(mapsPlaceId: String) async throws -> RemoteGym? { throw GymCatalogError.offline }
    func publicListings(gymId: UUID) async throws -> PublicListings { throw GymCatalogError.offline }
    func publicItems(kindId: String) async throws -> [RemoteItem] { throw GymCatalogError.offline }
    func findOrCreateGym(mapsPlaceId: String, name: String, address: String?, latitude: Double?,
                         longitude: Double?) async throws -> UUID { throw GymCatalogError.signedOut }
    func share(_ request: ShareRequest) async throws -> ShareResult { throw GymCatalogError.signedOut }
    func confirm(listingId: UUID) async throws -> Int { throw GymCatalogError.signedOut }
    func uploadSharedPhoto(_ data: Data, name: String) async throws -> String { throw GymCatalogError.signedOut }
    func deleteSharedPhoto(path: String) async throws { throw GymCatalogError.signedOut }
    func publicPhotoURL(path: String) -> URL? { nil }
}

extension AppEnvironment {
    static func makeGymSharing(options: LaunchOptions, sync: SyncCoordinator, gyms: GymRepository,
                               catalog: GymEquipmentCatalog, photoStore: GymPhotoStore,
                               now: @escaping () -> Date) -> GymSharing {
        let known = Set(catalog.kinds.map(\.id))
        let photoData: (String) -> Data? = { photoStore.data(file: $0) }
        #if DEBUG
        if options.fakeGymCatalog {
            return GymSharing(repository: gyms, transport: FakeGymCatalogTransport(), knownKinds: known,
                              photos: GymPhotoCache(store: photoStore) { _, _ in GymPhotoFixture.jpegData() },
                              photoData: photoData, now: now)
        }
        #endif
        let transport: any GymCatalogTransport = sync.auth.map { SupabaseGymCatalogTransport(client: $0.client) }
            ?? UnavailableGymCatalogTransport()
        return GymSharing(repository: gyms, transport: transport, knownKinds: known,
                          photos: GymPhotoCache.live(store: photoStore), photoData: photoData, now: now)
    }

    /// UI tests keep photos in tmp (a `-diskStore` relaunch keeps them, `-resetStore` drops them); real runs use
    /// Application Support.
    static func makeGymPhotos(options: LaunchOptions) -> GymPhotoStore {
        guard options.inMemory else { return GymPhotoStore() }
        let name = options.diskStoreURL == nil ? "gymrollins-uitest-gym-photos-\(UUID().uuidString)"
            : "gymrollins-uitest-gym-photos"
        let store = GymPhotoStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        if options.resetStore { try? store.removeAll() }
        return store
    }

    /// Called once from `init`: a sign-in lets the queued shares go.
    func wireGymSharing() {
        sync.onGymIdsMoved = { [weak self] moves in self?.gymIdsMoved(moves) }
        sync.onSessionEnding = { [weak self] in self?.gymSharing.invalidate() }
        sync.onWillSignOut = { [weak self] in
            guard let self, let userId = self.sharingUserId else { return }
            await self.gymSharing.outbox.discardQueuedPhotos(userId: userId)
        }
        sync.onSignedIn = { [weak self] in
            guard let self else { return }
            Task { await self.runShareOutbox() }
        }
    }

    /// The picture another gym took of an item, to show on a listing that has none. It comes through the same limited
    /// downloader as a saved one (JPEG, 1 MB, a total deadline) and is kept in memory only; nil when it can't be had.
    func catalogPhoto(_ path: String) async -> UIImage? {
        let sharing = gymSharing
        if let cached = sharing.borrowedPictures.object(forKey: path as NSString) { return cached }
        guard let url = sharing.transport.publicPhotoURL(path: path) else { return nil }
        do {
            let image = try await sharing.photos.image(from: url)
            sharing.borrowedPictures.setObject(image, forKey: path as NSString)
            return image
        } catch {
            Self.log.error("Download of a borrowed gym photo failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Who is signed in

    /// The account a share or confirmation is queued for. Nil while signed out, and while the phone's data still
    /// belongs to another account (nothing goes up under the new one until that is settled).
    var sharingUserId: UUID? { sync.accountSwitchPending ? nil : sync.authState.userId }

    private func requireSharingUser() throws -> UUID {
        guard let id = sharingUserId else { throw GymCatalogError.signedOut }
        return id
    }

    // MARK: Refresh

    /// Downloads a Maps gym's shared listings into the local rows, then their pictures one at a time. A private gym
    /// and a gym with no account never touch the server beyond reads; offline leaves the cached rows as they are.
    func gymCatalogRefresh(gymId: UUID, force: Bool) async {
        let sharing = gymSharing
        guard !sharing.refreshing.contains(gymId), isMapsGym(gymId) else { return }
        sharing.refreshing.insert(gymId)
        defer { sharing.refreshing.remove(gymId) }
        let before = shownListings(gymId)
        do {
            let result = try await sharing.client.refresh(gymId: gymId, force: force)
            await downloadPhotos(result.photosToFetch)
            removeGymPhotos(result.filesToDelete)
        } catch {
            Self.log.error("Refresh of the shared catalogue failed: \(error.localizedDescription, privacy: .public)")
        }
        if shownListings(gymId) != before { gymsChanged() }
    }

    private func isMapsGym(_ id: UUID) -> Bool {
        do { return try gyms.gym(id)?.mapsPlaceId != nil }
        catch {
            Self.log.error("Read gym failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func shownListings(_ gymId: UUID) -> [GymListing] {
        (try? gyms.listings(gymId: gymId, includingUnsupported: true)) ?? []
    }

    /// One picture at a time, so a gym of forty photos never opens forty connections. A picture that fails is left for
    /// the next refresh; the listing just shows the stock photo meanwhile.
    private func downloadPhotos(_ fetches: [PhotoFetch]) async {
        for fetch in fetches {
            guard let url = gymSharing.transport.publicPhotoURL(path: fetch.path) else { continue }
            do {
                let file = try await gymSharing.photos.fetch(from: url)
                guard let listing = try gyms.listing(fetch.listingId), listing.photoFile == nil else {
                    removeGymPhotos([file])
                    continue
                }
                do {
                    if try !syncStore.setPhotoFile(listingId: fetch.listingId, file: file) { removeGymPhotos([file]) }
                } catch {
                    removeGymPhotos([file])
                    throw error
                }
            } catch {
                Self.log.error("Download of a shared gym photo failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Share, confirm, sync

    /// Queues the share for the signed-in account. Signed out, nothing is queued.
    func shareListing(_ id: UUID, forceNew: Bool = false) throws {
        try gymSharing.outbox.enqueueShare(listingId: id, ownerId: try requireSharingUser(), forceNew: forceNew)
        sharingChanged()
    }

    func confirmListing(_ id: UUID) throws {
        try gymSharing.outbox.enqueueConfirm(listingId: id, ownerId: try requireSharingUser())
        sharingChanged()
    }

    func retryShare(_ id: UUID) throws {
        try gymSharing.outbox.retry(listingId: id, ownerId: try requireSharingUser())
        sharingChanged()
    }

    /// "Yes, that's it" for a share that found the gym already lists it: mine goes, theirs is confirmed.
    func keepExistingListing(_ id: UUID, existing: UUID) throws {
        let photo = try gymSharing.outbox.keepExisting(listingId: id, existingId: existing,
                                                       ownerId: try requireSharingUser())
        removeGymPhotos(photo.map { [$0] } ?? [])
        sharingChanged()
    }

    /// "Synced to my account" for one listing; its private gym syncs with it.
    func syncListing(_ id: UUID) throws {
        _ = try requireSharingUser()
        try gyms.makeSynced(listing: id)
        gymsChanged()
    }

    /// "Sync to my account" on a private gym: the gym and the equipment on it. Each listing goes with the same tap.
    func syncGym(_ id: UUID) throws {
        _ = try requireSharingUser()
        try gyms.makeSynced(gym: id)
        for listing in try gyms.listings(gymId: id) where listing.visibility == .device {
            try gyms.makeSynced(listing: listing.id)
        }
        gymsChanged()
    }

    /// Lets the queue go, now that something was added to it.
    private func sharingChanged() {
        gymsChanged()
        Task { await runShareOutbox() }
    }

    func runShareOutbox() async {
        let outbox = gymSharing.outbox
        guard outbox.pendingCount > 0, let userId = sharingUserId else { return }
        await outbox.run(userId: userId)
        if let error = outbox.storageError {
            Self.log.error("Share queue failed: \(error.localizedDescription, privacy: .public)")
        }
        gymsChanged()
    }
}
