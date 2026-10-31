import Foundation
import GymCore
import GymData
import Supabase
import SwiftData
import Testing
@testable import GymSync

/// Two users and an anonymous client against the local stack, each on a phone of their own, with the real transports
/// and the rules from GymCore (`scripts/test-gym-e2e.sh` sets the environment and checks the tables afterwards).
@MainActor
@Suite(.enabled(if: supabaseConfigured, "Set SUPABASE_URL and SUPABASE_ANON_KEY to run against local Supabase"))
struct GymCatalogE2ETests {
    private nonisolated static let kinds = [
        EquipmentKind(id: "dumbbells", name: "Dumbbells", category: .freeWeight, load: .fixedSet),
        EquipmentKind(id: "adjustable-bench", name: "Adjustable bench", category: .bench, load: .none),
        EquipmentKind(id: "cable-station", name: "Cable station", category: .cable, load: .stack),
        EquipmentKind(id: "chest-press-machine", name: "Chest press", category: .machine, load: .stack),
        EquipmentKind(id: "pec-deck", name: "Pec deck", category: .machine, load: .stack),
    ]

    private nonisolated static let requirements = ExerciseRequirements(groups: [
        "c-db-press": [["dumbbells"], ["adjustable-bench"]],
        "c-machine-press": [["chest-press-machine"]],
        "c-pec-deck": [["pec-deck"]],
        "c-cable-fly": [["cable-station"]],
        "c-cable-crossover": [["cable-station"]],
        "c-pushup": [],
    ])

    private nonisolated static let exercises = [
        Exercise(id: "c-db-press", name: "Dumbbell Bench Press", bodyPart: "chest", equipment: "dumbbell",
                 target: "pectorals", secondary: ["triceps"]),
        Exercise(id: "c-machine-press", name: "Lever Chest Press", bodyPart: "chest", equipment: "leverage machine",
                 target: "pectorals", secondary: ["triceps"]),
        Exercise(id: "c-pec-deck", name: "Lever Seated Fly", bodyPart: "chest", equipment: "leverage machine",
                 target: "pectorals"),
        Exercise(id: "c-cable-fly", name: "Cable Middle Fly", bodyPart: "chest", equipment: "cable",
                 target: "pectorals", secondary: ["shoulders"]),
        Exercise(id: "c-cable-crossover", name: "Cable Crossover", bodyPart: "chest", equipment: "cable",
                 target: "pectorals", secondary: ["shoulders"]),
        Exercise(id: "c-pushup", name: "Push-Up", bodyPart: "chest", equipment: "body weight", target: "pectorals",
                 secondary: ["triceps"]),
    ]

    /// One phone: its own store, repository, catalogue client and share queue, talking to the server as `client`.
    @MainActor private struct Phone {
        let container: ModelContainer
        let repo: GymRepository
        let catalog: SupabaseGymCatalogTransport
        let client: GymCatalogClient
        let outbox: ShareOutbox

        init(_ supabase: SupabaseClient) throws {
            container = try GymStore.container(inMemory: true)
            repo = GymRepository(context: container.mainContext)
            catalog = SupabaseGymCatalogTransport(client: supabase)
            client = GymCatalogClient(repository: repo, transport: catalog,
                                      knownKinds: Set(GymCatalogE2ETests.kinds.map(\.id)), now: Date.init)
            outbox = ShareOutbox(repository: repo, transport: catalog,
                                 photoData: { _ in Data(repeating: 0xFF, count: 600) }, now: Date.init)
        }

        func mapsGym(_ place: String) throws -> Gym {
            try repo.addMapsGym(placeId: place, name: "Iron Works", address: "1 Main St", latitude: 52.5,
                                longitude: 13.4)
        }

        @discardableResult
        func add(_ gym: Gym, _ kind: String, loads: ListingLoads = .stack(maxKg: 90, stepKg: 5), brand: String? = nil,
                 photo: String? = nil, notes: String? = nil) throws -> GymListing {
            try repo.addListing(NewListing(gymId: gym.id, kindId: kind, brand: brand, loads: loads, quantity: 1,
                                           notes: notes, photoFile: photo))
        }

        func record(_ id: UUID) throws -> GymListingRecord? {
            try container.mainContext.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first
        }

        func share(_ listing: GymListing, as user: UUID) async throws {
            try outbox.enqueueShare(listingId: listing.id, ownerId: user)
            await outbox.run(userId: user)
        }
    }

    // MARK: - Helpers

    private func signUp() async throws -> Account {
        let account = try Account.fresh(email: "gym-\(UUID().uuidString.lowercased())@test.local")
        try await account.auth.signUp(email: account.email, password: IntegrationEnv.password)
        return account
    }

    private func anonClient() throws -> SupabaseClient {
        try IntegrationEnv.config().makeClient(storage: InMemoryAuthStorage())
    }

    private func place() -> String { "e2e-\(UUID().uuidString.lowercased())" }

    private func build(_ phone: Phone, _ gym: Gym) throws -> BuiltWorkout {
        let matcher = InventoryMatcher(requirements: Self.requirements, kinds: Self.kinds,
                                       inventory: try phone.repo.inventory(gymId: gym.id))
        return WorkoutBuilder(matcher: matcher, exercises: Self.exercises, history: [])
            .build(BuildRequest(muscles: [.chest], length: .medium, date: Date(timeIntervalSince1970: 20_400 * 86_400)))
    }

    /// Records a string for the shell script to look for (or not) in the tables.
    private func hand(_ role: String, _ marker: String) {
        guard let path = ProcessInfo.processInfo.environment["GYM_E2E_MARKERS_FILE"],
              let line = "\(role) \(marker)\n".data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private func report(_ listing: UUID, as account: Account) async throws {
        let params: [String: AnyJSON] = ["p_target_type": .string("listing"),
                                         "p_target_id": .string(listing.uuidString.lowercased()),
                                         "p_reason": .string("wrong-info")]
        try await account.auth.client.rpc("report_content", params: params).execute()
    }

    // MARK: - Criterion 2

    @Test func criterion2AnotherUserAndAnAnonymousClientBuildAChestWorkoutFromSharedListings() async throws {
        let a = try await signUp()
        let b = try await signUp()
        let phoneA = try Phone(a.auth.client)
        let placeId = place()
        let gymA = try phoneA.mapsGym(placeId)
        let shared = try [
            phoneA.add(gymA, "dumbbells", loads: .fixed(kg: [10, 15, 20])),
            phoneA.add(gymA, "adjustable-bench", loads: .none),
            phoneA.add(gymA, "cable-station", loads: .stack(maxKg: 80, stepKg: 5)),
            phoneA.add(gymA, "chest-press-machine", loads: .stack(maxKg: 100, stepKg: 5)),
            phoneA.add(gymA, "pec-deck", loads: .stack(maxKg: 80, stepKg: 5)),
        ]
        for listing in shared { try await phoneA.share(listing, as: a.userId) }
        let sharedState = try shared.map { try #require(try phoneA.repo.listing($0.id)) }
        #expect(sharedState.allSatisfy { $0.visibility == .shared && $0.uploadState == .uploaded })
        let ids = Set(shared.map(\.id))

        for (name, client) in [("user B", b.auth.client), ("anonymous", try anonClient())] {
            let phone = try Phone(client)
            let gym = try phone.mapsGym(placeId)
            _ = try await phone.client.refresh(gymId: gym.id, force: true)
            let inventory = try phone.repo.inventory(gymId: gym.id)
            #expect(Set(inventory.listings.map(\.id)) == ids, "\(name) sees all five")
            let built = try build(phone, gym)
            #expect(built.items.count == 4, "\(name)")
            #expect(built.thin.isEmpty, "\(name)")
            for item in built.items {
                #expect(!item.isBodyweightFill, "\(name): \(item.exercise.exerciseId)")
                #expect(!item.match.listingIds.isEmpty, "\(name): \(item.exercise.exerciseId)")
                #expect(Set(item.match.listingIds).isSubset(of: ids), "\(name): \(item.exercise.exerciseId)")
            }
        }
        try await a.deleteAccount()
        try await b.deleteAccount()
    }

    // MARK: - Criterion 4

    @Test func criterion4ASecondShareOfTheSameKindIsKeptAsAConfirmation() async throws {
        let a = try await signUp()
        let b = try await signUp()
        let phoneA = try Phone(a.auth.client)
        let phoneB = try Phone(b.auth.client)
        let placeId = place()
        let gymA = try phoneA.mapsGym(placeId)
        let original = try phoneA.add(gymA, "cable-station")
        try await phoneA.share(original, as: a.userId)

        let gymB = try phoneB.mapsGym(placeId)
        _ = try await phoneB.client.refresh(gymId: gymB.id, force: true)
        let mine = try phoneB.add(gymB, "cable-station", loads: .stack(maxKg: 70, stepKg: 10))
        try await phoneB.share(mine, as: b.userId)

        let waiting = try #require(try phoneB.repo.listing(mine.id))
        #expect(waiting.uploadState == .waitingForChoice)
        #expect(try phoneB.outbox.duplicates(listingId: mine.id).map(\.id) == [original.id])

        _ = try phoneB.outbox.keepExisting(listingId: mine.id, existingId: original.id, ownerId: b.userId)
        await phoneB.outbox.run(userId: b.userId)
        #expect(try phoneB.repo.listing(mine.id) == nil)
        #expect(try phoneB.repo.listing(original.id)?.confirmCount == 1)

        let server = try await phoneB.catalog.publicListings(gymId: try #require(phoneB.repo.gym(gymB.id)?.remoteId)).listings
        #expect(server.map(\.id) == [original.id])
        #expect(server.first?.confirmCount == 1)
        #expect(server.first?.confirmedByMe == true)

        _ = try await phoneA.client.refresh(gymId: gymA.id, force: true)
        let theirs = try #require(try phoneA.repo.listing(original.id))
        #expect(theirs.confirmCount == 1)
        #expect(theirs.isOwn)
        try await a.deleteAccount()
        try await b.deleteAccount()
    }

    // MARK: - A lost answer

    /// Sends the first share to the real server and then drops the answer, as a connection lost on the way back does.
    private final class LosesTheFirstAnswer: GymCatalogTransport, @unchecked Sendable {
        let base: SupabaseGymCatalogTransport
        private let lock = NSLock()
        private var lost = false
        init(_ base: SupabaseGymCatalogTransport) { self.base = base }

        func publicGym(mapsPlaceId: String) async throws -> RemoteGym? { try await base.publicGym(mapsPlaceId: mapsPlaceId) }
        func publicListings(gymId: UUID) async throws -> PublicListings { try await base.publicListings(gymId: gymId) }
        func publicItems(kindId: String) async throws -> [RemoteItem] { try await base.publicItems(kindId: kindId) }
        func findOrCreateGym(mapsPlaceId: String, name: String, address: String?, latitude: Double?,
                             longitude: Double?) async throws -> UUID {
            try await base.findOrCreateGym(mapsPlaceId: mapsPlaceId, name: name, address: address, latitude: latitude,
                                           longitude: longitude)
        }
        func share(_ request: ShareRequest) async throws -> ShareResult {
            let result = try await base.share(request)
            let first = lock.withLock { () -> Bool in defer { lost = true }; return !lost }
            if first { throw GymCatalogError.offline }
            return result
        }
        func confirm(listingId: UUID) async throws -> Int { try await base.confirm(listingId: listingId) }
        func uploadSharedPhoto(_ data: Data, name: String) async throws -> String {
            try await base.uploadSharedPhoto(data, name: name)
        }
        func deleteSharedPhoto(path: String) async throws { try await base.deleteSharedPhoto(path: path) }
        func deleteAllPhotos() async throws { try await base.deleteAllPhotos() }
        func detachAllPhotos() async throws { try await base.detachAllPhotos() }
        func report(targetType: GymTargetType, targetId: UUID, reason: ReportReason, note: String?) async throws {
            try await base.report(targetType: targetType, targetId: targetId, reason: reason, note: note)
        }
        func blockAuthor(targetType: GymTargetType, targetId: UUID) async throws {
            try await base.blockAuthor(targetType: targetType, targetId: targetId)
        }
        func unblockAll() async throws -> Int { try await base.unblockAll() }
        func isAdmin() async throws -> Bool { try await base.isAdmin() }
        func moderationQueue() async throws -> [ModerationEntry] { try await base.moderationQueue() }
        func moderate(targetType: GymTargetType, targetId: UUID, action: ModerationAction) async throws -> String? {
            try await base.moderate(targetType: targetType, targetId: targetId, action: action)
        }
        func moderationPhotoDeleted(path: String) async throws { try await base.moderationPhotoDeleted(path: path) }
        func publicPhotoURL(path: String) -> URL? { base.publicPhotoURL(path: path) }
    }

    @Test func aShareWhoseAnswerWasLostIsRetriedIntoOneListing() async throws {
        let account = try await signUp()
        let phone = try Phone(account.auth.client)
        let flaky = LosesTheFirstAnswer(phone.catalog)
        let outbox = ShareOutbox(repository: phone.repo, transport: flaky,
                                 photoData: { _ in Data(repeating: 0xFF, count: 600) }, now: Date.init)
        let gym = try phone.mapsGym(place())
        let listing = try phone.add(gym, "cable-station", photo: "mine.jpg")
        try outbox.enqueueShare(listingId: listing.id, ownerId: account.userId)

        await outbox.run(userId: account.userId)
        #expect(outbox.pendingCount == 1, "the answer was lost, so the share is still queued")
        let photo = try #require(try phone.record(listing.id)?.remotePhotoPath)
        let serverGym = try #require(try phone.repo.gym(gym.id)?.remoteId)

        await outbox.run(userId: account.userId)
        #expect(outbox.pendingCount == 0)
        #expect(try phone.record(listing.id)?.uploadStateRaw == UploadState.uploaded.rawValue)
        #expect(try phone.record(listing.id)?.remotePhotoPath == photo, "the photo is not uploaded twice")
        let onServer = try await phone.catalog.publicListings(gymId: serverGym).listings
        #expect(onServer.map(\.id) == [listing.id], "one row on the server")
        try await account.deleteAccount()
    }

    // MARK: - Borrowed photo

    @Test func aListingWithoutAPhotoBorrowsOneFromTheCatalogueUntilItIsFlagged() async throws {
        let a = try await signUp()
        let b = try await signUp()
        let c = try await signUp()
        let d = try await signUp()
        let phoneA = try Phone(a.auth.client)
        let phoneB = try Phone(b.auth.client)
        let gymA = try phoneA.mapsGym(place())
        let withPhoto = try phoneA.add(gymA, "cable-station", brand: "E2E Hammer", photo: "a.jpg")
        try await phoneA.share(withPhoto, as: a.userId)
        let photoName = try #require(try phoneA.repo.listing(withPhoto.id).flatMap { _ in
            try phoneA.container.mainContext.fetch(FetchDescriptor<GymListingRecord>()).first?.remotePhotoPath
        })

        let gymB = try phoneB.mapsGym(place())
        let without = try phoneB.add(gymB, "cable-station", brand: "E2E Hammer")
        try await phoneB.share(without, as: b.userId)
        let serverB = try await phoneB.catalog.publicListings(gymId: try #require(phoneB.repo.gym(gymB.id)?.remoteId)).listings
        #expect(serverB.first?.photoPath == nil, "share_listing with no photo stores none")

        _ = try await phoneB.client.refresh(gymId: gymB.id, force: true)
        let borrowed = try #require(try phoneB.repo.listing(without.id)).item
        #expect(borrowed.catalogPhotoPath == photoName)
        #expect(borrowed.catalogPhotoListingId == withPhoto.id)
        #expect(try phoneB.repo.listing(without.id)?.photoFile == nil)

        let url = try #require(phoneB.catalog.publicPhotoURL(path: photoName))
        let (_, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")

        for reporter in [b, c, d] { try await report(withPhoto.id, as: reporter) }
        _ = try await phoneB.client.refresh(gymId: gymB.id, force: true)
        let after = try #require(try phoneB.repo.listing(without.id)).item
        #expect(after.catalogPhotoPath == nil)
        #expect(after.catalogPhotoListingId == nil)

        _ = try? await a.auth.client.storage.from("gym-photos").remove(paths: [photoName])
        for account in [a, b, c, d] { try await account.deleteAccount() }
    }

    // MARK: - Criterion 6

    @Test func criterion6AThisPhoneOnlyGymAndListingNeverReachAnyTable() async throws {
        let a = try await signUp()
        let tag = UUID().uuidString.lowercased()
        let phone = try Phone(a.auth.client)
        let deviceGym = "e2e-private-gym-\(tag)", deviceNote = "e2e-private-note-\(tag)"
        let deviceBrand = "e2e-private-brand-\(tag)", mapsNote = "e2e-maps-note-\(tag)"
        let syncedGym = "e2e-synced-gym-\(tag)"

        let home = try phone.repo.addPrivateGym(name: deviceGym, address: "e2e-private-address-\(tag)")
        try phone.add(home, "cable-station", brand: deviceBrand, photo: "a.jpg", notes: deviceNote)
        let maps = try phone.mapsGym(place())
        try phone.add(maps, "cable-station", notes: mapsNote)
        // The control: the same machinery must carry a synced gym, or an empty result below would prove nothing.
        let synced = try phone.repo.addPrivateGym(name: syncedGym, address: nil)
        try phone.repo.makeSynced(gym: synced.id)

        let defaults = UserDefaults(suiteName: "gym-e2e-\(tag)")!
        defer { UserDefaults.standard.removePersistentDomain(forName: "gym-e2e-\(tag)") }
        let store = SyncStore(context: phone.container.mainContext, defaults: defaults)
        let engine = SyncEngine(store: store, transport: SupabaseTransport(client: a.auth.client))
        await engine.sync()
        await phone.outbox.run(userId: a.userId)
        _ = try await phone.client.refresh(gymId: home.id, force: true)
        _ = try await phone.client.refresh(gymId: maps.id, force: true)
        await engine.sync()

        for marker in [deviceGym, deviceNote, deviceBrand, mapsNote, "e2e-private-address-\(tag)"] {
            hand("absent", marker)
        }
        hand("present", syncedGym)
        let own = try #require(try phone.repo.listing(try phone.repo.listings(gymId: home.id).first!.id))
        #expect(own.visibility == .device)
        #expect(own.photoFile == "a.jpg")
        #expect(try phone.repo.listings(gymId: maps.id).first?.visibility == .device)
        // The account stays: deleting it would remove the control row too. The script reads the tables, then removes
        // every gym-*@test.local user.
    }
}
